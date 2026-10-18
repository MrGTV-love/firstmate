# sourced by scenario scripts; builds a disposable Lavish sweep fixture. Usage: mk_fixture <labdir>
mk_session() {  # <store-dir> <artifact> <status> <queued> <updated-at|->
  mkdir -p "$1"
  perl -MJSON::PP -MCwd=realpath -MDigest::SHA=sha256_hex -e '
    my ($dir,$art,$status,$queued,$updated)=@ARGV; my $path="$dir/state.json"; my $doc={sessions=>{}};
    if (-f $path) { open my $in,"<",$path or die; local $/; $doc=decode_json(<$in>); }
    my $real=realpath($art) // die "missing artifact"; my $key=substr(sha256_hex($real),0,16);
    my $s={key=>$key,file=>$real,url=>"http://127.0.0.1:14387/session/$key",status=>$status,pending_prompts=>$queued+0};
    $s->{updated_at}=$updated unless $updated eq "-"; $doc->{sessions}{$key}=$s;
    open my $out,">",$path or die; print $out encode_json($doc);' "$@"
}
mk_board() {  # <home> <name>
  mkdir -p "$1/boards"; printf '<h1>%s</h1>\n' "$2" > "$1/boards/$2.html"; printf '%s\n' "$(cd "$1/boards" && pwd -P)/$2.html"
}
lab_env() {  # prints env assignments as words for use with env
  echo "PATH=$LAB/fakebin:$PATH FM_HOME=$LAB FM_PROCEVENT_CLAIM_ROOT=$LAB/procevent-claims LAVISH_AXI_STATE_DIR=$LAB/lavish-state"
}
