#!perl
use v5.34.0;
use warnings;

use Test::More;
use Test::Deep;

use lib 't/lib';
use lib 'lib';
use Linear::TestClient;
use Linear::Client;

my %TEST_TEAMS = (
  igg => { id => 'team-IGG', key => 'IGG', name => 'Eagles' },
  ste => { id => 'team-STE', key => 'STE', name => 'Steelers' },
);

my %TEST_USERS = (
  rasha => { id => 'user-123', displayName => 'rasha', name => 'Rasha M' },
  rjbs  => { id => 'user-234', displayName => 'rjbs',  name => 'Rik S' },
);

my $AUTH_USER_ID  = 'user-123';
my $DEFAULT_TEAM_ID  = 'team-IGG';

my $client = Linear::TestClient->new({
  auth_token  => 'fake-token',
  authenticated_userId => $AUTH_USER_ID,
  default_team_id => $DEFAULT_TEAM_ID,

  teams => \%TEST_TEAMS,
  users => \%TEST_USERS,
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
    title       => "eat more scrapple",
    description => q{}, # This seems weird, right? -- rjbs, 2021-10-28
    teamId      => $DEFAULT_TEAM_ID,
    assigneeId  => $AUTH_USER_ID,
  }),
  "self-assigned with ++",
);

plan_results_ok(
  ">> rasha eat more shawarma",
  superhashof({
    title       => "eat more shawarma",
    description => q{}, # This seems weird, right? -- rjbs, 2021-10-28
    teamId      => $DEFAULT_TEAM_ID,
    assigneeId  => $TEST_USERS{rasha}{id},
  }),
  "user, no team, no description",
);

plan_results_ok(
  '>> rasha@igg eat more pie',
  superhashof({
    title       => "eat more pie",
    description => q{}, # This seems weird, right? -- rjbs, 2021-10-28
    teamId      => $TEST_TEAMS{igg}{id},
    assigneeId  => $TEST_USERS{rasha}{id},
  }),
  "user, team, no description",
);

plan_results_ok(
  ">> ste eat more cake",
  {
    # Note: we didn't use superhashof() here because we want to make sure that
    # assigneeId wasn't set, and there's not "does-not-exist" test to use
    # easily with Test::Deep. -- rjbs, 2021-12-10
    title       => "eat more cake",
    description => q{}, # This seems weird, right? -- rjbs, 2021-10-28
    teamId      => $TEST_TEAMS{ste}{id},
    priority    => 0,
  },
  "no user, team, no description",
);

plan_results_ok(
  '>> rjbs bake a cake --- Remember, the best cake is pie.',
  superhashof({
    title       => "bake a cake",
    description => q{Remember, the best cake is pie.},
    teamId      => $DEFAULT_TEAM_ID,
    assigneeId  => $TEST_USERS{rjbs}{id},
  }),
  "user, no team, description",
);

# TODO: Tests to write next...
#   ++ title
#   ++ title flags
#   ++ title flags break description
#   >> username title
#   >> user@team title
#   >> team title

done_testing;
