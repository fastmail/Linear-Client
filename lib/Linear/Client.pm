use v5.34.0;
use warnings;

package Linear::Client;
use Moose;

use Cpanel::JSON::XS;
use Future::AsyncAwait;
use GraphQL::Miranda;
use LWP::UserAgent;
use Net::Async::HTTP;
use IO::Async::Loop;
use experimental 'signatures';

has api_url => (
  is      => 'ro',
  default => q{https://api.linear.app/graphql},
);

has auth_token => (
  is  => 'ro',
  isa => 'Str',
  required => 1,
);

has _http => (
  is      => 'ro',
  lazy    => 1,
  default => sub ($self, @) {
    my $loop = IO::Async::Loop->new();
    my $http = Net::Async::HTTP->new();
    $loop->add( $http );

    return $http;
  },
);

my sub cached_attr ($name, %arg) {
  my $query = $arg{query};
  Carp::confess("no query given") unless $query;

  my $xform = $arg{xform};
  Carp::confess("no xform given") unless $xform;

  my $cache_attr_name = "_$name\_cache";
  my $clearer_name    = "_clear_$cache_attr_name";
  my $plural          = $arg{plural} // "${name}s";

  has $cache_attr_name => (
    is      => 'ro',
    lazy    => 1,
    clearer => $clearer_name,
    default => sub ($self) {
      return {
        cached_at => time,
        # We should allow the query to be a sub that generates things based on
        # client properties, but for now... whatever. -- rjbs, 2021-11-12
        value     => $self->do_query($query)->then($xform),
      }
    }
  );

  Sub::Install::install_sub({
    as    => $plural,
    code  => async sub ($self) {
      my $cache = $self->$cache_attr_name;

      return await $cache->{value} if time - $cache->{cached_at} < 300
                                   && ! $cache->{value}->is_failed
                                   && ! $cache->{value}->is_cancelled;

      # The value in the cache was no good. Failed, old, I dunno.  Let's clear
      # it and try again. -- rjbs, 2021-11-12

      $self->$clearer_name;
      return await $self->$cache_attr_name->{value};
    },
  });

  Sub::Install::install_sub({
    as    => "lookup_$name",
    code  => async sub ($self, $key) {
      my $dict = await $self->$plural;
      return $dict->{ $key };
    }
  });
}

cached_attr team => (
  query => q[
    query Teams {
      teams { nodes { id key name } }
    }
  ],
  xform => sub ($res) {
    return {
      map {; lc $_->{key} => $_ } $res->{data}{teams}{nodes}->@*
    };
  },
);

cached_attr user => (
  query => q[
    query User {
      users { nodes { id displayName name } }
    }
  ],
  xform => sub ($res) {
    my $dict = {};

    NODE: for my $node ($res->{data}{users}{nodes}->@*) {
      unless ($node->{displayName}) {
        warn "no display name for $node->{name} // $node->{id}!\n";
        next NODE;
      }

      $dict->{ lc $node->{displayName} } = $node;
    }

    return $dict;
  },
);

has default_team_id => (
  is => 'ro',
);

async sub plan_from_input ($self, $input) {
  my %issue = (
    description => q{},
  );

  my $assignee_id;
  my $team_id;
  my $issue_name;

  # ++ foo bar baz
  # >> user foo bar baz
  # >> user@team foo bar baz
  # >> team foo bar baz  <--- left unimplemented for now

  $input =~ s/\A\s+//; # Trim leading whitespace just in case.

  if ($input =~ s/\A\+\+\s+//) {
    $assignee_id = await $self->get_authenticated_userId;
    $issue_name = $input;
  } elsif ($input =~ s/\A>>\s+//) {
    (my $target, $input) = split /\s+/, $input, 2;

    my $username;
    my $teamname;

    if ($target =~ /@/) {
      ($username, $teamname) = split /@/, $target, 2;
    } else {
      $username = $target;
    }

    my $user = await $self->lookup_user($username);
    die "can't find user for $username" unless $user;

    $assignee_id = $user->{id};

    if ($teamname) {
      my $team_obj = await $self->lookup_team($teamname);
      die "can't find team for $teamname" unless $team_obj;
      $team_id = $team_obj->{id};
    }

    $issue_name = $input;
  } else {
    Carp::confess("no ++ no >> no plan");
  }

  $team_id //= $self->default_team_id;

  unless ($team_id) {
    Carp::confess("can't create plan without team id");
  }

  $issue{title}  = $issue_name;
  $issue{teamId} = $team_id;
  $issue{assigneeId} = $assignee_id;

  return \%issue;
}

async sub get_authenticated_userId ($self) {
  my $user = await $self->do_query(q[
    query Me {
      viewer {
        id
      }
    }
  ]);

  return $user->{data}{viewer}{id};
}

async sub do_query {
  my ($self, $query, $variables, $arg) = @_;
  $arg //= {};

  if ($arg->{actor_id_as}) {
    my $actor_id = await $self->get_authenticated_userId();
    $variables->{$_} //= $actor_id for $arg->{actor_id_as}->@*;
  }

  my $res = await $self->_http->do_request(
    method => 'POST',
    uri    => $self->api_url,
    content_type => 'application/json',
    content      => encode_json({ query => $query, variables => $variables }),
    headers => {
      Authorization => $self->auth_token,
    },
  );

  return Future->fail('Linear API failure', res => $res->as_string)
    unless $res->is_success;

  return decode_json($res->decoded_content(charset => undef))
}

async sub create_issue ($self, $plan) {
  await $self->do_query(
    q[
      mutation IssueCreate (
        $assigneeId: String,
        $title: String!,
        $description: String,
        $teamId: String!,
      ) {
        issueCreate (
          input: {
            assigneeId: $assigneeId
            title: $title
            description: $description
            teamId: $teamId
          }
        ) {
          success
          issue {
            id
            identifier
            title
            team { id name }
          }
        }
      }
    ],
    $plan,
    { actor_id_as => [ qw(assigneeId) ] },
  );
}

async sub search_issues ($self, $search) {
  # The classic LiquidPlanner search buddy behavior here was:
  #   parse search  :  text  -> hunks
  #   compile search:  hunks -> search arguments
  #   execute search:  search arguments -> result
  #
  # Let's start by implementing execute, which *should* help indicate what kind
  # of things need to be in compile and parse anyway.

  # Pagination:
  #   NEXT PAGE:
  #   after : X - cursor id to search after
  #   first : count of items after cursor start (from "after")
  #
  #   PREV PAGE:
  #   before: X - cursor id to search before
  #   last  : count of items before cursor start (from "before")
  #
  #   orderBy: how to sort
  #

  # Issue query filters look like this:
  #   query issues(filter: { assignee: { id: { eq: "$user_id" } } }) {
  #
  # Here, a quick reference on what filters can be sent to an issues query,
  # including only those I think we'll need out of the gate!
  #
  # and: (compound filter)
  # or : (compount filter)
  #
  # assignee    : to whom we have assigned the issue
  # createdAt   : when it was created
  # creator     : who created it
  # cycle       : scheduled when
  # description : issue description contains...
  # dueDate     : when it's due
  # estimate    : issue estimate
  # labels      : labels on issue
  # priority    : issue priority
  # project     : project
  # snoozed*    : (there are filters for snoozing)
  # startedAt   : when work started
  # state       : what state it's in
  # team        : team of the issue
  # title       : issue title contains...
  # updatedAt   : when it was last updated
  state %inflate = (
    assignee => sub ($id)   { return { id   => { eq => $id    } } },
    priority => sub ($i)    { return { eq => $i } },
    project  => sub ($id)   { return { id   => { eq => $id    } } },
    state    => sub ($name) { return { name => { eq => $name  } } },
    team     => sub ($id)   { return { id   => { eq => $id    } } },
  );

  my %filter;
  KEY: for my $key (keys %$search) {
    if (ref $search->{$key}) {
      $filter{$key} = $search->{$key};
      next KEY;
    }

    if ($inflate{$key}) {
      $filter{$key} = $inflate{$key}->($search->{$key});
      next KEY;
    }

    Carp::confess("Don't know what to do with value $search->{$key} for $key");
  }

  # XXX: I am deeply unsure about the byte/text boundary here and will need to
  # think about it with my thinking at on. -- rjbs, 2021-11-19
  my $selection = GraphQL::Miranda->selection_set(
    issues => {
      args    => { filter => \%filter },
      select  => [
        nodes => {
          select => [
            qw(identifier title priority),
            team  => [ qw(name id) ],
          ],
        },
      ],
    },
  );

  my $query = "query {\n" . $selection->as_string("  ") . "\n}\n";

  await $self->do_query($query);
}

no Moose;
1;
