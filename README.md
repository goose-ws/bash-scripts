# bash-scripts

This is a collection of bash scripts I've hacked together over time which may be useful enough that I'm sharing them on GitHub

**Please do not use or expect anything from the 'testing' branch to work. Only scripts from the 'main' branch are polished enough to be expected to work reliably. And even then, consider them 'beta v2' stable, not full production stable.**

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
| A script meant to update a dynamic IP address via Linode's DNS manager. |
| Link to Script: [linode-dynamic-dns.bash](https://github.com/goose-ws/bash-scripts/blob/main/linode-dynamic-dns.bash) |
| Link to `.env` File: [linode-dynamic-dns.env](https://github.com/goose-ws/bash-scripts/blob/main/linode-dynamic-dns.env.example) |

---

<<<<<<< HEAD
| `plex-dlp-mirror.bash` |
| :---: |
| A script that mirrors content to Plex, powered by yt-dlp under the hood. Requires [yq](https://github.com/mikefarah/yq). |
| Link to Script: [plex-dlp-mirror.bash](https://github.com/goose-ws/bash-scripts/blob/main/plex-dlp-mirror.bash) |
| Link to `.env` File: [plex-dlp-mirror.env](https://github.com/goose-ws/bash-scripts/blob/main/plex-dlp-mirror.env.example) |
| Link to Source `.env` File: [00 - Sample.env](https://github.com/goose-ws/bash-scripts/blob/main/plex-dlp-mirror.sources/00%20-%20Sample.env.example) |

---

=======
>>>>>>> testing
| `plex-update-tba.bash` |
| :---: |
| A script meant to find media files with the name "TBA" or "TBD" on your Plex Media Server, and issue the necessary commands to refresh their metadata. Requires [yq](https://github.com/mikefarah/yq). |
| Link to Script: [plex-update-tba.bash](https://github.com/goose-ws/bash-scripts/blob/main/plex-update-tba.bash) |
| Link to `.env` File: [plex-update-tba.env](https://github.com/goose-ws/bash-scripts/blob/main/plex-update-tba.env.example) |

---

| `sonarr-group-notifications.bash` |
| :---: |
| ~~A script meant to group Sonarr import notifications if a bunch of the same series item are in the queue. This is meant to send one big notification of all items for that series, rather than getting spammed with a thousand individual notifications.~~ **This script is currently undergoing a total rewrite, and will be available again...soon™** |

---

| `sonarr-update-tba.bash` |
| :---: |
| A script meant to find media files with the name "TBA" or "TBD" in your Sonarr library, and issue the necessary commands to Sonarr to attempt to rename those files. |
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
- [ ] Update [update-plex-in-docker.bash](https://github.com/goose-ws/bash-scripts/blob/main/update-plex-in-docker.bash) to destroy/re-create the container, rather than just restart it (helps clean up old/unnecessary files)

### Done ✓

- [x] Update [captive-dns.bash](https://github.com/goose-ws/bash-scripts/blob/main/captive-dns.bash) to new standard
- [x] Updated Telegram sending function to support super groups, silent notifications
- [x] Update Docker container IP address detection to deal with containers with multiple networking types
- [x] Update [linode-dynamic-dns.bash](https://github.com/goose-ws/bash-scripts/blob/main/linode-dynamic-dns.bash) to new standard
- [x] Update [update-plex-in-docker.bash](https://github.com/goose-ws/bash-scripts/blob/main/update-plex-in-docker.bash) to offer to use ChuckPA's database repair/optimization tool between updates
