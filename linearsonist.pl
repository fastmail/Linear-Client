use v5.34.0;
use warnings;
use Cpanel::JSON::XS;
use LWP::UserAgent;
use Data::Dumper;
use feature qw(signatures);
no warnings qw(experimental::signatures);

binmode STDOUT, ":utf8";

my $url = q{https://api.linear.app/graphql};
my $lwp = LWP::UserAgent->new;
$lwp->default_header(Authorization => "lin_api_JoCSn1NbRqgSgrsk1GQS5DAvjUErHaFBIYc1GRSk");

my $JSON = Cpanel::JSON::XS->new->pretty->canonical;

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

sub plan_from_input ($input) {
 # if it starts with ++, then set get_authenticated_user() as value to assignee key in %task
 if ($input =~ /\++/) {
     $task{assigneeId} = get_authenticated_userId();
 };
 # grab everything before ! and set it to $title
 my ($title, $team_name) = split /!/, $input, 2;
 $task{title} = $title;
};

sub get_authenticated_userId {
  my $user = do_query(q[
    query Me {
      viewer {
        id
      }
    }
  ]);
  my $decoded = decode_json($user);
  return $decoded->{'data'}{'viewer'}{'id'};
};

sub do_query {
  my ($query, $variables) = @_;

  my $res = $lwp->post(
    $url,
    'Content-Type' => 'application/json',
    Content => encode_json({ query => $query, variables => \%task }),
  );
  warn "<<<" . $res->request->as_string . "\n>>>\n";;

  die $res->as_string unless $res->is_success;

  warn  $JSON->encode(decode_json($res->content));
  return $JSON->encode(decode_json($res->content));
};

sub create_issue ($input) {
  plan_from_input($input);
  # do mutation with values from %task
  do_query(
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
    \%task,
  );
};

create_issue("++ eat more scrapple");
