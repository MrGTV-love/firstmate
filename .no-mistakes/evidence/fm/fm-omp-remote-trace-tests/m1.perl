$_ .= "  sed -i '' 's/^harness=.*/harness=codex/' \"\$meta\"\n" if /remote launch returned without endpoint metadata/;
