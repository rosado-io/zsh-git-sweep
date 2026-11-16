#!/usr/bin/env zsh
# Child shell for terminal integration tests. Arguments stay quoted by the caller.
emulate -L zsh
source "$1"
cd "$2" || exit 1
shift 2
"$@"
result=$?
print -r -- "SESSION-RESULT:$result"
