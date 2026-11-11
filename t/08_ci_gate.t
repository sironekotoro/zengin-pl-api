use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP;
use Cwd qw(abs_path);

my $root = abs_path('.');
my $dir = tempdir(CLEANUP => 1);
open my $gh, '>', "$dir/gh" or die $!;
print {$gh} <<'SH';
#!/usr/bin/env bash
[[ "${MOCK_FAILURE:-}" != 1 ]] || exit 1
for arg in "$@"; do
  if [[ "$arg" == */workflows/* && "${MOCK_RACE:-}" == 1 && -f "$MOCK_MARKER" ]]; then
    printf '%s' "$MOCK_RUNS" | jq '.[0].workflow_runs[0].run_attempt = 2'; exit
  fi
  if [[ "$arg" == */workflows/* ]]; then printf '%s' "$MOCK_RUNS"; exit; fi
  if [[ "$arg" == */runs/*/attempts/*/jobs* ]]; then
    [[ "$arg" == */runs/2/attempts/1/jobs* ]] || exit 1
    [[ "${MOCK_RACE:-}" != 1 ]] || touch "$MOCK_MARKER"
    printf '%s' "$MOCK_JOBS"; exit
  fi
done
exit 1
SH
close $gh;
chmod 0755, "$dir/gh";
local $ENV{PATH} = "$dir:$ENV{PATH}";
my $sha = 'a' x 40;
my $run = { id=>2, run_attempt=>1, head_sha=>$sha, head_branch=>'chore/update-zengin-pl', event=>'workflow_dispatch', status=>'completed', conclusion=>'success' };
sub job { +{name=>$_[0], status=>'completed', conclusion=>'success'} }
sub passes {
    my ($runs, $jobs, $required) = @_;
    local $ENV{MOCK_RUNS} = ref($runs) ? encode_json($runs) : $runs;
    local $ENV{MOCK_JOBS} = ref($jobs) ? encode_json($jobs) : $jobs;
    $required //= '["test","docker"]';
    system('bash', '-c', "source '$root/bin/lib/zengin-pl-verify.sh'; workflow_ci_success repo test.yml chore/update-zengin-pl '$sha' '$required' >/dev/null 2>&1");
    return $? == 0;
}
my $runs = [{workflow_runs=>[$run]}];
my $jobs = [{jobs=>[job('test'),job('docker')]}];
ok(passes($runs,$jobs), 'exact workflow run and both required jobs pass');
ok(passes($runs,[{jobs=>[job('test')]},{jobs=>[job('docker')]}]), 'all job pages are combined');
ok(!passes($runs,[{jobs=>[job('unrelated')]}]), 'unrelated success cannot satisfy gate');
ok(!passes($runs,[{jobs=>[job('test')]}]), 'missing docker blocks');
ok(!passes($runs,[{jobs=>[job('docker')]}]), 'missing test blocks');
for my $state ('failure','cancelled','skipped','neutral','timed_out',undef) {
    my $j=job('docker'); $j->{conclusion}=$state;
    ok(!passes($runs,[{jobs=>[job('test'),$j]}]), 'non-success conclusion blocks');
}
my $pending=job('docker'); $pending->{status}='in_progress';
ok(!passes($runs,[{jobs=>[job('test'),$pending]}]), 'pending job blocks');
ok(!passes($runs,[{jobs=>[job('test'),job('test'),job('docker')]}]), 'duplicate required job is ambiguous');
ok(!passes($runs,[{jobs=>[job('Perl 5.36')]}],'["Perl 5.36","Perl 5.38","Perl 5.40","Perl 5.42"]'), 'partial upstream matrix blocks');
ok(passes($runs,[{jobs=>[map {job("Perl $_")} qw(5.36 5.38 5.40 5.42)]}],'["Perl 5.36","Perl 5.38","Perl 5.40","Perl 5.42"]'), 'full upstream matrix passes');
for my $field (qw(head_sha head_branch event)) {
    my %bad=%$run; $bad{$field}='wrong';
    ok(!passes([{workflow_runs=>[\%bad]}],$jobs), "$field mismatch blocks");
}
my %old=%$run; $old{id}=1;
my %failed=%$run; $failed{conclusion}='failure';
ok(!passes([{workflow_runs=>[\%old]},{workflow_runs=>[\%failed]}],$jobs), 'latest failed run blocks older success across pages');
ok(!passes([], $jobs), 'no workflow run blocks');
ok(!passes('not json', $jobs), 'malformed response blocks');
{ local $ENV{MOCK_FAILURE}=1; ok(!passes($runs,$jobs), 'API error blocks'); }
{ local $ENV{MOCK_RACE}=1; local $ENV{MOCK_MARKER}="$dir/race";
  ok(!passes($runs,$jobs), 'rerun attempt changing during job fetch blocks'); }
done_testing;
