use v5.24.0;
use warnings;

package Linear::Client;
use Moose;

# ABSTRACT: a client for Linear, the project management tool

use Cpanel::JSON::XS;
use Future::AsyncAwait;

use GraphQL::Miranda;
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

has debug_flogger => (
  is => 'ro',
);

sub maybe_log ($self, $arg) {
  my $flogger = $self->debug_flogger;
  return unless $flogger;

  $flogger->log($arg);
}

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

# Sure, this is a hack, but it's probably about the right level of
# sophistication/hackiness for the problem at hand.  Here we go:
#
# Cached attributes aren't the hack.  They're fine.  It's a way to say "when
# you ask for a team by key, we'll look in our cached team data.  If we don't
# have that data, or it's out of date, we'll fetch the team data from Linear.
# That means that we're always returning Futures.  All this is fine!
#
# The hack is that we want to have multiple Linear::Client objects that share
# this cache.  First off:  **don't forget** that this means the data needs to
# be things that are equally visible to all users.  If we do know that, then
# it's safe to store the cache in some external storage we've been handed.
# That's what we'll do!  It will let us make one Linear::Client per Synergy
# user, so most GraphQL work is done with the right authz, but they can all
# share locally cached state when appropriate.
#
# We took some notes on a different object structure to make this less hacky,
# but it's going to complicate things, and right now the goal is just to cross
# the finish line.
has _cache_guts => (
  is => 'ro',
  default => sub {  {}  },
);

my sub cached_attr ($name, %arg) {
  my $query = $arg{query};
  Carp::confess("no query given") unless $query;

  my $xform = $arg{xform};
  Carp::confess("no xform given") unless $xform;

  my $cache_attr_name = "_$name\_cache";
  my $clearer_name    = "_clear_$cache_attr_name";
  my $plural          = $arg{plural} // "${name}s";

  Sub::Install::install_sub({
    as    => $cache_attr_name,
    code  => sub ($self) {
      # If we've got a cache entry in the shared state, use that.  Otherwise,
      # make a new entry in it.
      my $guts = $self->_cache_guts;
      return $guts->{$name} //= {
        cached_at => time,
        # We should allow the query to be a sub that generates things based on
        # client properties, but for now... whatever. -- rjbs, 2021-11-12
        value     => $self->do_query($query)->then($xform),
      };
    }
  });

  Sub::Install::install_sub({
    as    => $clearer_name,
    code  => sub ($self) {
      delete $self->_cache_guts->{$name};
      return;
    },
  });

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
      return $dict->{ lc $key };
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

cached_attr label => (
  query => q[
    query IssueLabels {
      issueLabels { nodes { id name } }
    }
  ],
  xform => sub ($res) {
    return {
      map {; lc $_->{name} => $_->{id} } $res->{data}->{issueLabels}{nodes}->@*
    }
  }
);

cached_attr state => (
  query => q[
    query WorkFlowState {
      workflowStates {
        nodes { id name type team { id name } }
      }
    }
  ],
  xform => sub ($res) {
    return {
      map {; lc $_->{name} => $_->{id} } $res->{data}->{workflowStates}{nodes}->@*
    }
  }
);

my $LINESEP = qr{(
  # space or newlines
  # then three dashes and maybe some leading spaces
  (^|\s+) ---\s*
  |
  \n
)}nxs;

has helper => (
  is => 'ro',
  isa => 'Object',
);

async sub lookup_team_or_user ($self, $string) {
  my $helper   = $self->helper;
  my $username = $helper ? $helper->normalize_username($string) // $string
                         : $string;

  my $user = await $self->lookup_user($username);

  return (user => $user) if $user;

  my $team_name = $helper ? $helper->normalize_team_name($string) // $string
                          : $string;

  my $team = await $self->lookup_team($team_name);

  return (team => $team) if $team;

  return;
}

async sub plan_from_input ($self, $input) {
  my %issue = (
    description => q{},
    priority    => 0,
  );

  # This object can help us do directory lookups and the like, if provided.
  # -- rjbs, 2021-12-20
  my $helper = $self->helper;

  my $assignee_id;
  my $team_id;
  my $issue_title;
  my $stateId;

  my $username;
  my $teamname;

  my $plusplus = qr{\+\+};
  my $angle = qr{>>};

  $input =~ s/\A\s+//; # Trim leading whitespace just in case.

  # set description if given
  if ($input =~ $LINESEP) {
    ($input, $issue{description}) = split /$LINESEP/, $input, 2;
  };

  # set priority if given
  if ($input =~ s/\s*\(!\)//) {
    $issue{priority} = 1;
  };

  # if ++ or if >>
  if ($input =~ s/\A$plusplus\s+//) {
    $issue_title = $input;
    my $auth_user = await $self->get_authenticated_user;

    $assignee_id = $auth_user->{id};
    $username    = $auth_user->{username};
  } elsif ($input =~ s/\A$angle\s+//) {
    # if >> split into target/input, and assign target accordingly (triage,
    # user, team)
    my $target;
    ($target, $input) = split /\s+/, $input, 2;
    $issue_title = $input;

    if ($target =~ /\A(\w+)@(\w+)/) {
      # if target is user@team, set user as assignee.
      $username = $1;
      $teamname = $2;

      if ($helper) {
        $username = $helper->normalize_username($username) // $username;
      }

      my $user = await $self->lookup_user($username);
      die "can't find user for $username\n" unless $user;

      $assignee_id = $user->{id};
    } else {
      # check if $target is a team, and if not then look up the user
      my $teams = await $self->teams();
      if (exists $teams->{$target}) {
        $teamname = $target;
      } else {
        if ($helper) {
          $target = $helper->normalize_username($target) // $target;
        }

        my $user = await $self->lookup_user($target);
        die "can't find user for $target\n" unless $user;
        $username = $target;
        $assignee_id = $user->{id};
      }
    }
  } else {
    die "Can't prepare a plan without ++ or >>\n";
  }

  if ($teamname) {
    my $team_obj = await $self->lookup_team($teamname);
    die "can't find team for $teamname\n" unless $team_obj;
    $team_id = $team_obj->{id};
  } else {
    $team_id = $helper
             ? $helper->team_id_for_username($username)
             : undef;
  }

  unless ($team_id) {
    die "can't create plan without team id\n";
  }

  $issue{title}  = $issue_title;
  $issue{teamId} = $team_id;
  $issue{assigneeId} = $assignee_id if $assignee_id;
  $issue{stateId} = $stateId if $stateId;

  return \%issue;
}

async sub get_authenticated_user ($self) {
  my $user = await $self->do_query(q[
    query Me {
      viewer {
        id
        username: displayName
      }
    }
  ]);

  return $user->{data}{viewer};
}

async sub do_query {
  my ($self, $query, $variables, $arg) = @_;
  $arg //= {};

  if ($arg->{actor_id_as}) {
    my $actor = await $self->get_authenticated_user;
    my $actor_id = $actor->{id};
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
        $priority: Int,
        $labelIds: [String!],
        $stateId: String,
      ) {
        issueCreate (
          input: {
            assigneeId: $assigneeId
            title: $title
            description: $description
            teamId: $teamId
            priority: $priority
            labelIds: $labelIds
            stateId: $stateId
          }
        ) {
          success
          issue {
            id
            identifier
            title
            team { id name }
            priority
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
  state %replace = (
    closed => sub ($closed) {
      return $closed
        ? (state => { type => {  in => [ qw( canceled completed ) ] } })
        : (state => { type => { nin => [ qw( canceled completed ) ] } });
    },
    label => sub ($label) {
      # This is a mess, too... -- rjbs, 2021-12-20
      return (labels => { name => { eq => $label } });
    },
  );

  state %inflate = (
    assignee => sub ($id)   {
      return { id   => { eq => $id    } } if defined $id;
      return { null => JSON::true() };
    },
    priority => sub ($i)    { return { eq => $i } },
    project  => sub ($id)   { return { id   => { eq => $id    } } },
    state    => sub ($name) { return { name => { eq => $name  } } },
    team     => sub ($id)   { return { id   => { eq => $id    } } },
  );

  my %filter;
  KEY: for my $key (keys %$search) {
    if ($replace{$key}) {
      # This is somewhat bold!  What about conflicts? -- rjbs, 2021-12-20
      my %result = $replace{$key}->($search->{$key});
      @filter{ keys %result } = values %result;
      next KEY;
    }

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

  $self->maybe_log([ "given search %s built filter %s", $search, \%filter ]);

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
            state => [ qw(name type) ],
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
