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

sub plan_from_input ($self, $input) {
  # if ++ assign to me, which we get through query ME
  # regex it so that whatever is after the ! is the team
  my %task = (
    description => q{},
    teamId => 'c4196244-4381-498b-ae0b-9288fc459cdd',
  );
  #my %task = {
  #  title => $title
  #  description => $description
  #  assigneeId => $assignee
  #  team => $teamId
  #  state => $stateId
  #};

  # grab everything before ! and set it to $title
  my ($title, $team_name) = split /!/, $input, 2;
  $task{title} = $title;

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
    my $actor_id = $self->get_authenticated_userId();

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
  my $plan = $self->plan_from_input($input);
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

  return $teams;
}



no Moose;
1;
