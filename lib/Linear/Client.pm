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

cached_attr label => (
  query => q[
    query IssueLabels {
      issueLabels { nodes { id name } }
    }
  ],
  xform => sub ($res) {
    return {
      map {; lc $_->{name} => $_->{id}} $res->{data}->{issueLabels}{nodes}->@*
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

has default_team_id => (
  is => 'ro',
);

my $LINESEP = qr{(
  # space or newlines
  # then three dashes and maybe some leading spaces
  (^|\s+) ---\s*
  |
  \n
)}nxs;

async sub plan_from_input ($self, $input) {
  my %issue = (
    description => q{},
    priority    => 0,
  );

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

  #set priority if given
  if($input =~ s/\(!\)//) {
    $issue{priority} = 1;
  };

  # if ++ or if >>
  if ($input =~ s/\A$plusplus\s+//) {
    $issue_title = $input;
    $assignee_id = await $self->get_authenticated_userId;
  } elsif ($input =~ s/\A$angle\s+//) { # if >> split into target/input, and assign target accordingly (triage, user, team)
    my $target;
    ($target, $input) = split /\s+/, $input, 2;
    $issue_title = $input;
    if ($target eq "triage") { # if target is triage set label to "support blocker"
      my $label = await $self->lookup_label("support blocker");
      my @labelIds = [$label];
    } elsif ($target =~ /\A(\w+)@(\w+)/) { #if target is user@team, set user as assignee. Team lookup on line 232
      $username = $1;
      $teamname = $2;
      my $user = await $self->lookup_user($username);
      $assignee_id = $user->{id};
    } else { # check if $target is a team, and if not then look up the user
      my $teams = await $self->teams();
      if (exists $teams->{$target}) {
        $teamname = $target; # team lookup on line 232
      } else {
        my $user = await $self->lookup_user($target);
        die "can't find user for $target" unless $user;
        $assignee_id = $user->{id};
      }
    }
  } else {
     Carp::confess("no ++ no >> no plan");
	 }

  # set $team_id
  if ($teamname) {
    my $team_obj = await $self->lookup_team($teamname);
    die "can't find team for $teamname" unless $team_obj;
    $team_id = $team_obj->{id};
  } else {
    $team_id = $self->default_team_id;
  };

  unless ($team_id) {
    Carp::confess("can't create plan without team id");
  };

  $issue{title}  = $issue_title;
  $issue{teamId} = $team_id;
  $issue{assigneeId} = $assignee_id if $assignee_id;
  $issue{stateId} = $stateId if $stateId;

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

no Moose;
1;
