#!/bin/zsh
set -eu
task_root="${0:A:h:h}"
cd "$task_root"
if [[ ! -x build/depotdownloader/DepotDownloader ]]; then
  print -u2 'Missing DepotDownloader. Prepare the official macOS ARM64 release first.'
  exit 1
fi
print 'Sign in with your Steam account to fetch licensed BG3 Windows reference binaries.'
print 'Downloads are filtered to game executables and DLSS libraries; game data is excluded.'
read -r 'steam_username?Steam account username: '
if [[ -z "$steam_username" ]]; then
  print -u2 'A Steam account username is required.'
  exit 1
fi
print 'DepotDownloader will prompt for your password and any required Steam Guard verification.'
exec build/depotdownloader/DepotDownloader -app 1086940 -os windows -osarch 64 \
  -filelist tools/windows-reference-files.txt -dir build/windows-reference \
  -loginid 108694026 -username "$steam_username" -validate
