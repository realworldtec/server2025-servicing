Ubuntu SSH keys are NOT read from here by any build script.

Ubuntu's answer file (linux/user-data) carries its keys inline. Paste your Ubuntu key material
directly into linux/user-data:
  - INBOUND public key(s)  -> the  ssh: authorized-keys:  list
  - OUTBOUND private+public -> the two  write_files:  content blocks

This folder exists only to keep your Ubuntu key files in one place if you like. See docs/SSH-KEYS.md.
