#!perl
use v5.34.0;
use warnings;

use Test::More;
use Test::Deep;

use lib 't/lib';
use Linear::TestClient;

my $AUTH_USER_ID  = 'user-1234';
my $DEFAULT_TEAM  = 'team-9876';

my $client = Linear::TestClient->new({
  auth_token  => 'fake-token',
  authenticated_userId => $AUTH_USER_ID,
  default_team_id => $DEFAULT_TEAM,
});

sub plan_results_ok {
  my ($input, $want, $desc) = @_;

  local $Test::Builder::Level = $Test::Builder::Level + 1;

  my $plan = $client->plan_from_input($input)->get;

  cmp_deeply($plan, $want, $desc);
}

plan_results_ok(
  "++ eat more scrapple",
  superhashof({
    title => "eat more scrapple",
    description => q{}, # This seems weird, right? -- rjbs, 2021-10-28
    teamId => $DEFAULT_TEAM,
  }),
  "the simplest plan of all",
);

done_testing;
