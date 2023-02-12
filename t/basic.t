#!perl
use v5.28.0;
use warnings;

use utf8;

use Test::More;
use Test::Deep;

use lib 't/lib';
use lib 'lib';
use Linear::TestClient;
use Linear::Client;

my %TEST_TEAMS = (
  igg => { id => 'team-IGG', key => 'IGG', name => 'Eagles' },
  ste => { id => 'team-STE', key => 'STE', name => 'Steelers',
           states => { nodes => [ { name => 'To Discuss', id => 99 } ] } },
);

my %TEST_USERS = (
  rasha => { id => 'user-123', displayName => 'rasha', name => 'Rasha M' },
  rjbs  => { id => 'user-234', displayName => 'rjbs',  name => 'Rik S' },
);

my %TEST_PROJECTS = (
  cake    => {
    id     => 'pCake',
    slugId => 'ZZZZ',
    name   => 'Cake Week',
    teams   => [
      { id => $TEST_TEAMS{igg}{id} },
    ],
  },
  biscuit => {
    id      => 'pBiscuit',
    slugId  => 'HHHH',
    name    => 'Biscuit Week',
    teams   => [
      { id => $TEST_TEAMS{ste}{id} },
    ],
  },
);

my $AUTH_USER_ID  = 'user-123';
my $DEFAULT_TEAM_ID  = 'team-IGG';

package Linear::TestHelper {
  use experimental 'signatures';

  sub new { bless {}, $_[0] }

  sub normalize_username   ($self, $username)  { $username }
  sub team_id_for_username ($self, $username)  { $DEFAULT_TEAM_ID }
  sub normalize_team_name  ($self, $team_name) { $team_name }

  sub project_ids_for_tag ($self, $tag) {
    return Future->done('HHHH') if $tag eq 'hash';
    return Future->done('DUPE', 'dupe') if $tag eq 'dupe';
    return Future->done;
  }
}

my $client = Linear::TestClient->new({
  auth_token  => 'fake-token',
  authenticated_user => { username => 'jfblogs', id => $AUTH_USER_ID },

  helper => Linear::TestHelper->new,

  teams => \%TEST_TEAMS,
  users => \%TEST_USERS,
  projects => \%TEST_PROJECTS,
});

sub plan_results_ok {
  my ($input, $want, $desc) = @_;

  local $Test::Builder::Level = $Test::Builder::Level + 1;

  my $plan = $client->plan_from_input($input)->get;

  cmp_deeply($plan, $want, $desc);
}

sub plan_results_error {
  my ($input, $want, $desc) = @_;

  local $Test::Builder::Level = $Test::Builder::Level + 1;

  my @failure = $client->plan_from_input($input)->failure;

  # This is stupid.  Our whole "die on resolve error" is probably a mistake.
  # On the other hand, it's easy.  For now, since we're dying with a \n at the
  # end (to suppress trace information), let's chomp that \n off here so that
  # we don't need to specify it in our expectations. -- rjbs, 2021-12-10
  chomp $failure[0] if ! ref $failure[0];

  cmp_deeply(\@failure, $want, $desc);
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

plan_results_ok(
  '>> rjbs pay your bills (!)',
  superhashof({
    title       => "pay your bills",
    description => q{},
    teamId      => $DEFAULT_TEAM_ID,
    assigneeId  => $TEST_USERS{rjbs}{id},
    priority    => 1, # 1 is always urgent
  }),
  "user, no team, description, urgent!!",
);

plan_results_ok(
  '>> rjbs pay your bills 🔥',
  superhashof({
    title       => "pay your bills",
    description => q{},
    teamId      => $DEFAULT_TEAM_ID,
    assigneeId  => $TEST_USERS{rjbs}{id},
    priority    => 1, # 1 is always urgent
  }),
  "user, no team, description, urgent!! (emoji)",
);

plan_results_ok(
  '>> rjbs@ste discuss your problems :phone:',
  superhashof({
    title       => "discuss your problems",
    description => q{},
    teamId      => $TEST_TEAMS{ste}{id},
    assigneeId  => $TEST_USERS{rjbs}{id},
    stateId     => 99
  }),
  "issue for discussion with :phone:",
);

plan_results_ok(
  '>> rjbs@ste discuss your problems (?)',
  superhashof({
    title       => "discuss your problems",
    description => q{},
    teamId      => $TEST_TEAMS{ste}{id},
    assigneeId  => $TEST_USERS{rjbs}{id},
    stateId     => 99
  }),
  "issue for discussion with (?)",
);

plan_results_ok(
  '>> rjbs@ste ask about hash (?) ##hash',
  superhashof({
    title       => "ask about hash",
    description => q{},
    teamId      => $TEST_TEAMS{ste}{id},
    assigneeId  => $TEST_USERS{rjbs}{id},
    stateId     => 99,
    projectId   => 'pBiscuit',
  }),
  "(?) and ##hash",
);

plan_results_ok(
  '>> rjbs@ste ask about hash ##hash (?)',
  superhashof({
    title       => "ask about hash",
    description => q{},
    teamId      => $TEST_TEAMS{ste}{id},
    assigneeId  => $TEST_USERS{rjbs}{id},
    stateId     => 99,
    projectId   => 'pBiscuit',
  }),
  "##hash and (?)",
);

plan_results_error(
  ">> rjbs duplicate project ##dupe",
  [
    re(qr{more than one}),
  ],
  "bad project tag: used twice",
);

plan_results_error(
  ">> rjbs duplicate project ##bogus",
  [
    re(qr{no project}),
  ],
  "bad project tag: unknown",
);

plan_results_error(
  '>> rjbs@igg duplicate project ##hash',
  [
    re(qr{isn't part of}),
  ],
  "bad project tag: team not in project",
);

plan_results_ok(
  <<~'END',
  >> rasha here's some code
  ```code block```
  ```code block```
  END
  superhashof({
    title       => "here's some code",
    description => "```\ncode block\n```\n```\ncode block\n```\n",
    teamId      => $DEFAULT_TEAM_ID,
    assigneeId  => $TEST_USERS{rasha}{id},
  }),
  "code blocks: adjust fences-without-newlines to have them (for Linear)",
);

plan_results_ok(
  <<~'END',
  >> rasha here's some code
  ```
  code block
  ```
  ```
  code block
  ```
  END
  superhashof({
    title       => "here's some code",
    description => "```\ncode block\n```\n```\ncode block\n```\n",
    teamId      => $DEFAULT_TEAM_ID,
    assigneeId  => $TEST_USERS{rasha}{id},
  }),
  "code blocks: we don't introduce unwanted extra newlines",
);

plan_results_ok(
  <<~'END',
  >> rjbs I am ```so``` clever!
  Look at me!
  END
  superhashof({
    title       => "I am ```so``` clever!",
    description => "Look at me!\n",
    teamId      => $DEFAULT_TEAM_ID,
    assigneeId  => $TEST_USERS{rjbs}{id},
  }),
  "code blocks: triple backticks mean nothing in issue title",
);

plan_results_ok(
  <<~'END',
  >> rjbs@ste do the hustle
  /project hash

  Look at me!
  END
  superhashof({
    title       => "do the hustle",
    description => "Look at me!\n",
    teamId      => $TEST_TEAMS{ste}{id},
    assigneeId  => $TEST_USERS{rjbs}{id},
    projectId   => 'pBiscuit',
  }),
  "/command lines",
);


plan_results_error(
  <<~'END',
  >> rjbs This will not be fine
  I have a
  ````
  very
  ````
  fenced code block
  END
  [
    re(qr{more than three backticks}),
  ],
  "code blocks: three backticks is just right, four is too many",
);

# TODO: Tests to write next...
#   ++ title
#   ++ title flags
#   ++ title flags break description
#   >> username title
#   >> user@team title
#   >> team title

plan_results_error(
  '>> michael play the saxophone',
  [
    q{can't find a user or team for "michael"},
  ],
  "fail to resolve user/team",
);

plan_results_error(
  'wait for Godot',
  [
    "Can't prepare a plan without ++ or >>",
  ],
  "non-plan string passed in",
);

plan_results_error(
  '>> zoltan foretell the future',
  [
    q{can't find a user or team for "zoltan"},
  ],
  "can't assign to unknown person",
);

plan_results_error(
  '>> zoltan@igg foretell the future',
  [
    q{can't find user for "zoltan"},
  ],
  "can't assign to unknown person at a known team",
);

plan_results_error(
  '>> igg make it stop raining (!)',
  [
    q{Can't create an urgent issue without a human assignee},
  ],
  "can't create an urgent issue without a human assignee"
);

done_testing;
