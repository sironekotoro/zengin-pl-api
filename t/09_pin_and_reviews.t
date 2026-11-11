use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP;
use MIME::Base64 qw(encode_base64);
use Cwd qw(abs_path);

my $root=abs_path('.');
my $dir=tempdir(CLEANUP=>1);
open my $fh, '>', "$dir/gh" or die $!;
print {$fh} <<'SH';
#!/usr/bin/env bash
[[ "${MOCK_ERROR:-}" != 1 ]] || exit 1
if [[ "$*" == *contents/zengin-pl.ref* ]]; then
  printf '%s' "$MOCK_CONTENT"
elif [[ "$*" == *compare/* ]]; then
  printf '%s' "$MOCK_COMPARE"
elif [[ "$*" == *graphql* && "$*" == *--paginate* && "$*" == *--slurp* && "$*" == *'after: $endCursor'* ]]; then
  printf '%s' "$MOCK_THREADS"
else
  exit 1
fi
SH
close $fh;
chmod 0755,"$dir/gh";
local $ENV{PATH}="$dir:$ENV{PATH}";
my $sha='a' x 40;
sub run_func {
    my ($function)=@_;
    my $out=`bash -c "source '$root/bin/auto-merge-zengin-pl-pr.sh'; $function" 2>/dev/null`;
    return ($? >> 8,$out);
}
for my $bytes ("$sha\n", $sha, "$sha\n\n", "$sha\r\n", "$sha\nextra\n", "$sha\0\n", " $sha\n", "", uc($sha)."\n") {
    open my $pin, '>', "$dir/pin" or die $!;
    binmode $pin; print {$pin} $bytes; close $pin;
    my ($local_exit,$local_out)=run_func("read_pin_file '$dir/pin'");
    is($local_exit==0?0:1, $bytes eq "$sha\n" ? 0 : 1, 'local pin reader enforces exact bytes');
    local $ENV{MOCK_CONTENT}=encode_json({type=>'file' ,path=>'zengin-pl.ref',encoding=>'base64',size=>length($bytes),content=>encode_base64($bytes)});
    my ($exit,$out)=run_func("pin_at_sha '$sha'");
    if ($bytes eq "$sha\n") {is($exit,0,'exact 41 bytes accepted');is($out,$sha,'returns exact pin');}
    else { isnt($exit,0,'noncanonical pin bytes rejected'); }
}
# Do not trust size metadata alone.
{ local $ENV{MOCK_CONTENT}=encode_json({type=>'file',path=>'zengin-pl.ref',encoding=>'base64',size=>41,content=>encode_base64("$sha\n\n")});
  my ($exit)=run_func("pin_at_sha '$sha'"); isnt($exit,0,'extra newline rejected despite claimed size'); }
{ local $ENV{MOCK_CONTENT}=encode_json({type=>'symlink',path=>'zengin-pl.ref',encoding=>'base64',size=>41,content=>encode_base64("$sha\n")});
  my ($exit)=run_func("pin_at_sha '$sha'"); isnt($exit,0,'symlink metadata rejected'); }
sub page {
    my ($nodes,$more)=@_;
    return {data=>{repository=>{pullRequest=>{reviewThreads=>{nodes=>$nodes,pageInfo=>{hasNextPage=>$more?JSON::PP::true:JSON::PP::false,endCursor=>'next'}}}}}};
}
my @resolved=map {{isResolved=>JSON::PP::true}} 1..100;
for my $case (
    ['all pages resolved',[page(\@resolved,1),page([{isResolved=>JSON::PP::true}],0)],0],
    ['unresolved on page two',[page(\@resolved,1),page([{isResolved=>JSON::PP::false}],0)],1],
    ['truncated pagination',[page(\@resolved,1)],1],
    ['missing GraphQL data',[{}],1],
    ['GraphQL errors',[{errors=>[{message=>'denied'}]}],1],
    ['unknown resolution',[page([{}],0)],1],
    ['empty result',[],1],
) {
    local $ENV{MOCK_THREADS}=encode_json($case->[1]);
    my ($exit)=run_func('review_threads_all_resolved 11');
    is($exit==0?0:1,$case->[2],$case->[0]);
}
{ local $ENV{MOCK_ERROR}=1; my ($exit)=run_func('review_threads_all_resolved 11'); isnt($exit,0,'transport error blocks'); }
for my $comparison ({merge_base_commit=>{sha=>$sha}}, {merge_base_commit=>{sha=>'b' x 40}}, {}) {
    local $ENV{MOCK_COMPARE}=encode_json($comparison);
    my ($exit)=run_func("head_contains_base '$sha' '" . ('c' x 40) . "'");
    my $expected=($comparison->{merge_base_commit}{sha}//'') eq $sha ? 0 : 1;
    is($exit==0?0:1,$expected,'compare API must prove current main is an ancestor');
}
done_testing;
