use v5.34.0;
use warnings;

package Linear::Client;
use Moose;

use Cpanel::JSON::XS;
use LWP::UserAgent;

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

has _lwp => (
  is   => 'ro',
  lazy => 1,
  default => sub ($self, @) {
    my $lwp = LWP::UserAgent->new;
    $lwp->default_header(Authorization => $self->auth_token);

    return $lwp;
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
};

sub get_authenticated_userId ($self) {
  my $user = $self->do_query(q[
    query Me {
      viewer {
        id
      }
    }
  ]);
  return $user->{data}{viewer}{id};
};

sub do_query {
  my ($self, $query, $variables, $arg) = @_;
  $arg //= {};

  if ($arg->{actor_id_as}) {
    my $actor_id = $self->get_authenticated_userId();

    $variables->{$_} //= $actor_id for $arg->{actor_id_as}->@*;
  }

  my $res = $self->_lwp->post(
    $self->api_url,
    'Content-Type' => 'application/json',
    Content => encode_json({ query => $query, variables => $variables }),
  );

  die $res->as_string unless $res->is_success;

  return decode_json($res->decoded_content(charset => undef));
}

sub create_issue ($self, $input) {
  my $plan = $self->plan_from_input($input);
  # do mutation with values from the plan
  $self->do_query(
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

no Moose;
1;
