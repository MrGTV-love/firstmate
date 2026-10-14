#!/usr/bin/env bash
x=$1
ls $x
[ $x = y ] && echo yes || echo no
