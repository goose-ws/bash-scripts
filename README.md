# bash-scripts

This is a collection of bash scripts I've hacked together over time which may be useful enough that I'm sharing them on GitHub

I have a moderate amount of skill in bash. I am no expert, but I am no novice either. There may be better ways to execute the flow of logic I am trying to achieve in these scripts. If you have a suggestion, I would welcome a pull request. If you have an issue, you are welcome to create an Issue or reach out to me on IRC. I idle in #goose on Libera, and usually respond within a few hours of being highlighted.

Unless otherwise noted, all scripts in this repository are covered by the [MIT liencse](https://github.com/goose-ws/bash-scripts/blob/main/LICENSE)

These scripts will generally work by sourcing the "Config" options to a `.env` file with the same base file name, and kept in the same directory. So for example, if you want to use the `captive-dns.bash` script, you will need to place `captive-dns.env` in the same directory next to it. The config file names are dynamic to the script file name. So if you wanted to rename `captive-dns.bash` to `force-dns.bash`, then your config file would need to be `force-dns.env` in the same directory.

I will generally try and write in a `-h` or `--help` flag as well, that you can run scripts with to see what options they have.

Scripts here include:

---

| `captive-dns.bash` |
| :---: |
| A script meant for the UniFi Dream Machine line, which can be used to force DNS to a specific DNS server. This can be useful to force devices which ignore the DNS server handed out by DHCP to use the DNS server of your choice, such as a Google Home. The script will run every minute to ensure your configured DNS server is actually working, and switch to backup option(s) if it is not. |
| Link to Script: [captive-dns.bash](https://github.com/goose-ws/bash-scripts/blob/main/captive-dns.bash) |
| Link to `.env` File: [captive-dns.env](https://github.com/goose-ws/bash-scripts/blob/main/captive-dns.env.example) |

---

| `linode-dynamic-dns.bash` |
| :---: |
| A script meant to update a dynamic IP address via Linode's DNS manager. Rather than a packaged `.env.example` file, this one generates the `.env` file when run with the `-c` option. |
| Link to Script: [linode-dynamic-dns.bash](https://github.com/goose-ws/bash-scripts/blob/main/linode-dynamic-dns.bash) |

---

| `sonarr-group-notifications.bash` |
| :---: |
| A script meant to group Sonarr import notifications if a bunch of the same series item are in the queue. This is meant to send one big notification of all items for that series, rather than getting spammed with a thousand individual notifications. |
| Link to Script: [sonarr-group-notifications.bash](https://github.com/goose-ws/bash-scripts/blob/main/sonarr-group-notifications.bash) |
| Link to `.env` File: [sonarr-group-notifications.env](https://github.com/goose-ws/bash-scripts/blob/main/sonarr-group-notifications.env.example) |

---

| `sonarr-update-tba.bash` |
| :---: |
| A script meant to find media files with the name "TBA" in your library, and issue the necessary commands to Sonarr to attempt to rename those files. It will also attempt to find and refresh metadata for "TBA" items in your Plex library, if configured to do so. |
| Link to Script: [sonarr-update-tba.bash](https://github.com/goose-ws/bash-scripts/blob/main/sonarr-update-tba.bash) |
| Link to `.env` File: [sonarr-update-tba.env](https://github.com/goose-ws/bash-scripts/blob/main/sonarr-update-tba.env.example) |

---

| `update-plex-in-docker.bash` |
| :---: |
| The Plex Media Server docker container installs the latest version within the container, each time it is started. Therefore, we cannot install PMS updates simply by waiting for a new version of the container. Rather, we must restart the container when an update is available. This script automates that process, with some sanity checks to make sure no one is watching anything first. |
| Link to Script: [update-plex-in-docker.bash](https://github.com/goose-ws/bash-scripts/blob/main/update-plex-in-docker.bash) |
| Link to `.env` File: [update-plex-in-docker.env](https://github.com/goose-ws/bash-scripts/blob/main/update-plex-in-docker.env.example) |

---

### Todo

- [ ] Re-write [sonarr-group-notifications.bash](https://github.com/goose-ws/bash-scripts/blob/main/sonarr-group-notifications.bash) to new standard, and to fix its behavior
- [ ] Update [linode-dynamic-dns.bash](https://github.com/goose-ws/bash-scripts/blob/main/linode-dynamic-dns.bash) to new standard
- [ ] Update [update-plex-in-docker.bash](https://github.com/goose-ws/bash-scripts/blob/main/update-plex-in-docker.bash) to destroy/re-create the container, rather than just restart it (helps clean up old/unnecessary files)

### Done ✓

- [x] Update [captive-dns.bash](https://github.com/goose-ws/bash-scripts/blob/main/captive-dns.bash) to new standard
