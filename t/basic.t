#!perl
use v5.34.0;
use warnings;

use Test::More;
use Test::Deep;

use Linear;

my $plan = Linear::plan_from_input("eat more scrapple");

cmp_deeply(
  $plan,
  {
    title => "eat more scrapple",
    description => q{}, # This seems weird, right? -- rjbs, 2021-10-28
    teamId => 'c4196244-4381-498b-ae0b-9288fc459cdd', # XXX Fix!
  },
  "correct task name",
);

done_testing;
