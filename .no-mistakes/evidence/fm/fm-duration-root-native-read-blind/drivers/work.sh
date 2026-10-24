#!/bin/bash
# Productive fixed batch: each step a short CPU-burning child that is reaped
# well before the next sample; the root shell itself mostly sleeps.
for i in $(seq 1 24); do
  perl -e '$t=time; my $x=0; for (1..2500000) { $x+=$_ }' 
  sleep 0.45
done
echo batch-done
