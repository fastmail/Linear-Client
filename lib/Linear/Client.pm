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

has _team_cache => (
  is      => 'ro',
  lazy    => 1,
  clearer => '_clear_team_cache',
  default => sub ($self) {
    my $teams_f = $self->do_query(q[
      query Teams {
        teams { nodes { id key name } }
      }
    ]);

    return {
      cached_at => time,
      value     => $teams_f->then(sub ($res) {
        Future->done({
           map {; lc $_->{key} => $_ } $res->{data}{teams}{nodes}->@*;
        });
      }),
    }
  }
);

async sub teams ($self) {
  my $cache = $self->_team_cache;

  return await $cache->{value} if time - $cache->{cached_at} < 300
                               && ! $cache->{value}->is_failed
                               && ! $cache->{value}->is_cancelled;

  # The value in the cache was no good. Failed, old, I dunno.  Let's clear it
  # and try again. -- rjbs, 2021-11-12

  $self->_clear_team_cache;
  return await $self->_team_cache->{value};
}

async sub team_for_key ($self, $team_key) {
  my $teams = await $self->teams;

  return $teams->{ $team_key };
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

no Moose;
1;
