use v5.34.0;
use warnings;

package Linear::Client;
use Moose;

use Cpanel::JSON::XS;
use Future::AsyncAwait;
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
    priority => 0,
  );

  my $assignee_id;
  my $team_id;
  my $issue_name;

	# We probably should not declare these variables unless we need them..
	my $username;
	my $teamname;

  # ++ foo bar baz
  # >> user foo bar baz
  # >> user@team foo bar baz
  # >> team foo bar baz

  $input =~ s/\A\s+//; # Trim leading whitespace just in case.

  my ($operator, $target, $rest) = split /\s+/, $input, 3;

  # split $target if user@team
  if ($target =~ /@/) {
    ($username, $teamname) = split /@/, $target, 2;
  } else {
    $username = $target;
	}

  # set $assignee_id based on operator and whether $username is a team or a person
  if ($operator eq "++") {
    $assignee_id = await $self->get_authenticated_userId;
	} elsif ($operator eq ">>"){
    # first check if $username is a team, and if not then look up the user
	  my $teams = await $self->teams();
    if(exists $teams->{$username}){
      $team_id = $teams->{$username}{id};
    } else {
      my $user = await $self->lookup_user($username);
      die "can't find user for $username" unless $user;
      $assignee_id = $user->{id};
    }
   } else {
     Carp::confess("no ++ no >> no plan");
	 }

  # set $team_id 
  if ($teamname) {
    my $team_obj = await $self->lookup_team($teamname);
    die "can't find team for $teamname" unless $team_obj;
    $team_id = $team_obj->{id};
  }

  # set priority if given
  if($rest =~ /\(!\)/) {
    $rest =~ s/\(!\)//; # Remove the (!) from the $rest string
    $issue{priority} = 1;
  }

  $issue_name = $rest;

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
        $priority: Int,
      ) {
        issueCreate (
          input: {
            assigneeId: $assigneeId
            title: $title
            description: $description
            teamId: $teamId
            priority: $priority
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

no Moose;
1;
