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
  is   => 'ro',
  lazy => 1,
  default => sub ($self, @) {
    my $loop = IO::Async::Loop->new();
    my $http = Net::Async::HTTP->new();
    $loop->add( $http );

    return $http;
  },
);

async sub _teamId_from_name($self, $input) {
    my $teams = await $self->get_teams();
    use Data::Dumper;
    for (@$teams) {
        if($_->{name} =~ $input) {
            return $_->{id};
        };
    };
    say "We don't have a $input team here";
}

sub _plan_from_input ($self, $input) {
  my %task = (
    description => q{},
  );

  my ($operator, $title, $team_name) = split /\++|>>|\@/, $input, 3;
  $task{title} = $title;
  if ($team_name) {
      $task{teamId} = $self->_teamId_from_name($team_name)->get;
  } else {
      $task{teamId} = 'c4196244-4381-498b-ae0b-9288fc459cdd';
  };
  return \%task;
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

async sub create_issue ($self, $input) {
  my $plan = $self->_plan_from_input($input);
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
};

async sub get_teams ($self) {
  my $teams = await $self->do_query(q[
    query Teams {
      teams {
        nodes {
          id
          name
        }
      }
    }
  ]);

  return $teams->{data}{teams}{nodes};
};


no Moose;
1;


