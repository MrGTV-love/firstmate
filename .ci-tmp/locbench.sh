f() { local LC_ALL=C; :; }
g() { :; }
for loc in C en_US.UTF-8; do
  export LC_ALL=$loc
  TIMEFORMAT="$loc localC x2000 %R"; time for ((i=0;i<2000;i++)); do f; done
  TIMEFORMAT="$loc plain x2000 %R"; time for ((i=0;i<2000;i++)); do g; done
done
