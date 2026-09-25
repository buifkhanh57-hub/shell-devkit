# shell-devkit

A collection of handy **bash** utility functions for daily dev work —
usable as a sourced library or as a CLI.

## Commands
```bash
./devkit.sh backup ~/myproject        # timestamped backup
./devkit.sh http_status https://github.com
./devkit.sh rand_password 20          # random password
./devkit.sh disk_alert 85             # disk usage warning
./devkit.sh largest_files . 5         # 5 largest files under .
./devkit.sh git_summary               # current branch + dirty files
```

Or source everything into your shell:
```bash
source devkit.sh
mkcd ~/code/new-project               # mkdir + cd helper
```
