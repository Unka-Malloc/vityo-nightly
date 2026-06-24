#!/bin/bash
cd $HOME/Unka-Malloc/vityo-nightly
git add .
git commit -m "fix: comment out removed ShellRuntimeModel API references in test files"
git push origin HEAD:integration/nightly-all-subbranches-20260624
