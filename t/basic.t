#!perl
use v5.34.0;
use warnings;

use Test::More;
use Test::Deep;

use lib 't/lib';
use lib 'lib';
use Linear::TestClient;
use Linear::Client;

my $AUTH_USER_ID  = 'user-1234';
my $DEFAULT_TEAM  = 'team-9876';
my $CLIENT_TEAM = 'team-7890';
my $PLUMBING_TEAM = 'team-3458';
my $RASHA = 'user-234r23';

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
    assigneeId => $AUTH_USER_ID,
  }),
  "the simplest plan of all",
);

#plan_results_ok(
#  ">> rasha eat more shawarma",
#  superhashof({
#    title => "eat more shawarma",
#    description => q{}, # This seems weird, right? -- rjbs, 2021-10-28
#    teamId => $DEFAULT_TEAM,
#    assigneeId => $RASHA,
#  }),
#  "the simplest plan of all",
#);

plan_results_ok(
  ">> rasha\@client eat more pie",
  superhashof({
    title => "eat more pie",
    description => q{}, # This seems weird, right? -- rjbs, 2021-10-28
    teamId => $CLIENT_TEAM,
    assigneeId => $RASHA,
  }),
  "user_at_team",
);

#plan_results_ok(
#  ">> client eat more cake",
#  superhashof({
#    title => "eat more cake",
#    description => q{}, # This seems weird, right? -- rjbs, 2021-10-28
#    teamId => $CLIENT_TEAM,
#    assigneeId => undef,
#  }),
#  "the simplest plan of all",
#);
# TODO: Tests to write next...
#   ++ title
#   ++ title flags
#   ++ title flags break description
#   >> username title
#   >> user@team title
#   >> team title

done_testing;
