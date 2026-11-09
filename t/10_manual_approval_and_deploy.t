use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP;
use Cwd qw(abs_path);
my $root=abs_path('.');
my $dir=tempdir(CLEANUP=>1);
my $sha='a' x 40;
sub approval {
    my ($payload,$overrides)=@_;
    local %ENV=%ENV;
    @ENV{qw(GITHUB_EVENT_NAME GITHUB_REF GITHUB_ACTOR GITHUB_TRIGGERING_ACTOR GITHUB_EVENT_PATH)} =
        ('workflow_dispatch','refs/heads/main','sironekotoro','sironekotoro',"$dir/event.json");
    @ENV{keys %{$overrides//{}}}=values %{$overrides//{}};
    open my $f,'>',"$dir/event.json" or die $!;
    print {$f} encode_json($payload);close $f;
    system('bash','-c',"source '$root/bin/auto-merge-zengin-pl-pr.sh'; manual_merge_approved 11 '$sha' >/dev/null 2>&1");
    return $?==0;
}
my $valid={sender=>{login=>'sironekotoro',type=>'User'},inputs=>{pr_number=>'11',head_sha=>$sha}};
ok(approval($valid,{}),'owner explicit dispatch bound to current PR/head passes');
for my $pair ([GITHUB_EVENT_NAME=>'schedule'],[GITHUB_EVENT_NAME=>'workflow_run'],[GITHUB_REF=>'refs/heads/other'],[GITHUB_ACTOR=>'someone-else'],[GITHUB_TRIGGERING_ACTOR=>'someone-else'],[GITHUB_TRIGGERING_ACTOR=>''],[GITHUB_EVENT_PATH=>"$dir/missing"]) {
    ok(!approval($valid,{$pair->[0]=>$pair->[1]}),"rejects incorrect $pair->[0]");
}
for my $bad ({}, {sender=>$valid->{sender},inputs=>{pr_number=>'12',head_sha=>$sha}},
    {sender=>$valid->{sender},inputs=>{pr_number=>'11',head_sha=>'b'x40}},
    {sender=>{login=>'sironekotoro',type=>'Bot'},inputs=>$valid->{inputs}},
    {sender=>{login=>'other',type=>'User'},inputs=>$valid->{inputs}}) {
    ok(!approval($bad,{}),'missing, stale or wrong-owner approval rejected');
}
open my $curl,'>',"$dir/curl" or die $!;
print {$curl} <<'SH';
#!/usr/bin/env bash
count=0; [[ ! -f "$MOCK_COUNT" ]] || count=$(cat "$MOCK_COUNT")
count=$((count+1)); echo "$count" > "$MOCK_COUNT"
echo "$*" >> "$MOCK_ARGS"
IFS=, read -ra sequence <<< "$MOCK_SEQUENCE"
state="${sequence[$((count-1))]:-${sequence[-1]}}"
case "$state" in
  failure) exit 22;;
  invalid) echo 'not json';;
  missing) echo '{}';;
  old) printf '{"api":{"git_sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}';;
  new) printf '{"api":{"git_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}';;
esac
SH
close $curl;chmod 0755,"$dir/curl";
sub deployment {
    my ($sequence)=@_;
    local %ENV=%ENV;
    $ENV{PATH}="$dir:$ENV{PATH}";
    $ENV{MOCK_SEQUENCE}=$sequence;
    $ENV{MOCK_COUNT}="$dir/count";$ENV{MOCK_ARGS}="$dir/args";
    $ENV{VERIFY_ATTEMPTS}=4;$ENV{VERIFY_DELAY_SECONDS}=0;
    unlink "$dir/count","$dir/args";
    my $out=`bash '$root/bin/verify-deployment.sh' 'https://service.example' '$sha' 2>&1`;
    my $exit=$?>>8;
    open my $f,'<',"$dir/args" or die $!;my @args=<$f>;close $f;
    return ($exit,\@args,$out);
}
for my $case (['new,new',0,2],['old,new,new',0,3],['failure,new,new',0,3],['invalid,new,new',0,3],['missing,new,new',0,3],['new,old,new,new',0,4],['old',1,4],['new,old,new,old',1,4],['failure',1,4]) {
    my ($exit,$args,$out)=deployment($case->[0]);
    is($exit==0?0:1,$case->[1],"deployment sequence $case->[0]");
    is(scalar @$args,$case->[2],'bounded attempts and consecutive-success requirement');
    like($args->[0],qr/Cache-Control: no-cache, no-store/,'explicit cache bypass');
    like($args->[0],qr/--max-time 15/,'per-request timeout');
    isnt($args->[0],$args->[1],'unique query on every attempt');
}
open my $wf,'<','.github/workflows/auto-merge-zengin-pl.yml' or die $!;
my $workflow=do {local $/;<$wf>};close $wf;
unlike($workflow,qr/^  (?:schedule|workflow_run):/m,'CI and schedule cannot grant merge approval');
like($workflow,qr/^      pr_number:/m,'explicit PR input required');
like($workflow,qr/^      head_sha:/m,'explicit SHA input required');
done_testing;
