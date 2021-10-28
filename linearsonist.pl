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
my $text = shift;
my %task;
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
 my ($title, $team_name) = $input =~ /(.*)!(.*)/;
 $task{title} = $title;
};

sub get_authenticated_userId {
  my $user = query(q[
      query Me {
        viewer {
          id
        }
      }
  ]);
  my $decoded = decode_json($user);
	return $decoded->{'data'}{'viewer'}{'id'};
};

sub query {
  my ($query) = @_;

  my $res = $lwp->post(
    $url,
    'Content-Type' => 'application/json',
    Content => encode_json({ query => $query, variables => \%task }),
  );

  die $res->as_string unless $res->is_success;

  return $JSON->encode(decode_json($res->content));
};

sub create_issue ($input) {
  plan_from_input($input);
  # do mutation with values from %task
# query(q[
#   mutation IssueCreate {
#     issueCreate (
#       input: {
# 				assigneeId: ""
#         title: ""
#         description: ""
#       }
#     ) {
#       success
#       issue {
#         id
#         title
#         team
#       }
#     }
#   }
# ]);
};

create_issue($text);

