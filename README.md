# Bash Script Collection

## About

This repository contains a collection of Bash scripts designed for various automation and utility tasks. These scripts are primarily passion projects. I have a moderate amount of skill in bash. I am certainly no expert, but I am no novice either. There are likely better ways to execute the flow of logic I am trying to achieve in these scripts! If you have a suggestion, I would welcome a pull request. All scripts require **Bash version 4 or greater** to run.

**Please do not use or expect anything from the 'testing' branch to work. Only scripts from the 'main' branch are polished enough to be expected to work reliably.**

If you encounter any issues or have questions, please raise an issue on the [GitHub Issues page](https://github.com/goose-ws/bash-scripts/issues) for the repository.

For bugs, feature requests, and enhancements, reach out via the [Issues page](https://github.com/goose-ws/bash-scripts/issues). If you just need support, reach out to me on IRC. I idle in `#goose` on: [irc://irc.ChatSpike.net/#goose](ChatSpike), [irc://irc.Libera.chat/#goose](Libera), [irc://irc.oftc.net/#goose](OFTC), [irc://irc.slashnet.org/#goose](SlashNet), and [irc://irc.SnooNet.org/#goose](SnooNet). I usually respond within a few hours of being highlighted.

## Scripts

Below is a list of scripts available in this repository, along with their descriptions, requirements, and installation instructions.

These scripts will generally work by sourcing the "Config" options to a `.env` file with the same base file name, and kept in the same directory.

So for example, if you want to use the `captive-dns.bash` script, you will need to place `captive-dns.env` in the same directory next to it.

The config file names are dynamic to the script file name. So if you wanted to rename `captive-dns.bash` to `force-dns.bash`, then your config file would need to be `force-dns.env` in the same directory.

## Dependencies

While the dependencies vary for each script, many depend on [Mike Farah's 'yq'](https://github.com/mikefarah/yq). While `jq` is great for json, I've found `yq` to better suit my needs, as it allows me to parse XML in the same way. There are some that still use `jq` as I wrote them before switching to `yq` -- I am likely to edit them in the future to depend on `yq` instead.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Contributing
I welcome any discussion and pull requests, as outlined above. I wrote these scripts for myself, but I'm sharing them with the world, as perhaps they can be useful to others in the same way that they've been useful to me. Scripts in this repository will always be freely available.

If you happen to find these scripts particularly helpful and have a few bucks to spare, you can [https://github.com/sponsors/goose-ws](buy me a drink)! No pressure at all, but any support is greatly appreciated!

---

### Captive DNS (`captive-dns.bash`)

* **Purpose**: Manages captive DNS on a UDM Pro, forcing all clients to use a specific DNS server via iptables. This is particularly useful for ensuring devices with hard-coded DNS (like Google Home) use your PiHole.
* **Requirements**:
    * UDM Pro running Unifi v2.4+ (Debian-based)
    * BoostChicken's [on-boot.d](https://github.com/unifi-utilities/unifios-utilities/tree/main/on-boot-script-2.x)
    * Dependencies: `awk`, `curl`, `date`, `grep`, `host`, `md5sum`, `iptables`, `sort`
* **Installation**:
    1.  Ensure BoostChicken's on-boot functionality is installed.
    2.  Place the script at `/data/scripts/captive-dns.bash` on your UDM Pro.
    3.  Make the script executable: `chmod +x /data/scripts/captive-dns.bash`.
    4.  Copy `captive-dns.env.example` to `captive-dns.env` in the same directory and customize it.
    5.  Run `/data/scripts/captive-dns.bash --install` to set up cron and on-boot execution.
* **Features**:
    * Forces DNS via iptables NAT prerouting rules.
    * Automatic failover to primary, secondary, or tertiary DNS servers based on availability tests.
    * Telegram notifications for DNS status changes and errors.
    * Self-update capability (`-u` or `--update`).
    * Manages a lockfile to prevent concurrent execution.

---

### Linode Dynamic DNS (`linode-dynamic-dns.bash`)

* **Purpose**: Updates a DNS record in Linode's DNS manager, primarily for keeping a dynamic DNS record current.
* **Requirements**:
    * Dependencies: `awk`, `curl`, `md5sum`
* **Installation**:
    1.  Download the `.bash` script and the `.env.example` file.
    2.  Rename `linode-dynamic-dns.env.example` to `linode-dynamic-dns.env` and customize it with your Linode API key and domain/record details.
    3.  Set the script to run on a cron job at your desired interval.
* **Features**:
    * Updates IPv4 (A records) and IPv6 (AAAA records).
    * Checks current IP against Linode's record before updating.
    * Telegram notifications for successful updates or errors.
    * Self-update capability (`-u` or `--update`).
    * Manages a lockfile to prevent concurrent execution.

---

### Plex DLP Mirror (`plex-dlp-mirror.bash`)

* **Docker**: The plan is to eventually convert this script to a standalone Docker container
* **Purpose**: Mirrors media from various sources (e.g., YouTube) in a format compatible with Plex TV shows (Plex Series Scanner and Personal Media Shows agent) or as audio tracks (where each song becomes its own album). It utilizes `yt-dlp` for downloading.
* **Requirements**:
    * Dependencies: `awk`, `cmp`, `convert`, `curl`, `date`, `docker`, `ffmpeg`, `find`, `grep`, `identify`, `mktemp`, `shuf`, `sort`, `sqlite3`, `xxd`, `yq`, `yt-dlp`
* **Installation**:
    1.  Download the `.bash` script and the `.env.example` file.
    2.  Rename `plex-dlp-mirror.env.example` to `plex-dlp-mirror.env` and customize it.
    3.  Set up your Plex library:
        * Type: TV Shows
        * Folders: Path to your `${outputDir}`
        * Advanced > Scanner: Plex Series Scanner
        * Advanced > Agent: Personal Media Shows
    4.  Create a source configuration directory (e.g., `plex-dlp-mirror.sources` in the same directory as the script).
    5.  Inside this directory, create `.env` files for each media source (see the example source env on GitHub).
    6.  Set the script to run via a cron job.
* **Features**:
    * Downloads and organizes videos as TV show seasons and episodes.
    * Can download audio-only, treating each track as a separate album.
    * Uses an SQLite database (`.plex-dlp-mirror.bash.db`) to track media, configurations, and Plex metadata.
    * Integrates with SponsorBlock to skip or mark segments in videos/audio.
    * Manages Plex metadata including series titles, summaries, posters, and watch status.
    * Handles Plex collections and playlists based on YouTube playlists.
    * Telegram and Discord notifications for downloads and errors.
    * Self-update capability (`-u` or `--update`).
    * Support for private playlists via cookies.
    * Media import functionality (`-i` or `--import-media`).
    * Manages a lockfile to prevent concurrent execution.

---

### Plex Update TBA (`plex-update-tba.bash`)

* **Purpose**: Searches your Plex Media Server for media items (episodes) titled "TBA" or "TBD" and attempts to refresh their metadata to get the correct titles.
* **Requirements**:
    * Dependencies: `awk`, `curl`, `md5sum`, `yq`
* **Installation**:
    1.  Download the `.bash` script and the `.env.example` file.
    2.  Rename `plex-update-tba.env.example` to `plex-update-tba.env` and customize it with your Plex server details.
    3.  Set the script to run via a cron job (e.g., hourly).
* **Features**:
    * Identifies episodes with "TBA" or "TBD" titles in your Plex library.
    * Refreshes metadata for identified items to attempt to update titles.
    * Telegram and Discord notifications for renamed items or errors.
    * Self-update capability (`-u` or `--update`).
    * Allows ignoring specific Plex libraries, series, seasons, or episodes via the `.env` file.
    * Manages a lockfile to prevent concurrent execution.

---

### Sonarr Group Notifications (`sonarr-group-notifications.bash`)

**This script is currently undergoing a total rewrite, and will be available again...soon™**

* ~~**Purpose**: Groups "On Import" notifications from Sonarr to send a single, consolidated message if multiple episodes of a series are imported around the same time, instead of one notification per episode.~~  
* ~~**Requirements**:~~  
    ~~* Dependencies: `awk`, `curl`, `jq`, `md5sum`, `sort`. `docker` if Sonarr is in Docker and script is outside.~~  
* ~~**Installation**:~~  
    ~~1.  Download the `.bash` script and the `.env.example` file.~~  
    ~~2.  Rename `sonarr-group-notifications.env.example` to `sonarr-group-notifications.env` and customize it.~~  
    ~~3.  If using Docker, place script and `.env` in a persistently mounted directory (e.g., `/config/`).~~  
    ~~4.  Make the script executable (`chmod +x`) and ensure it's owned by the user/group Sonarr runs as.~~  
    ~~5.  In Sonarr: Settings > Connect > Add Connection (+ Custom Script).~~  
        ~~* Name: Your choice (e.g., Grouped Telegram Notifications).~~  
        ~~* Notification Triggers: Check "On Import" ONLY.~~  
        ~~* Path: Absolute path to `sonarr-group-notifications.bash` (e.g., `/config/sonarr-group-notifications.bash` if in Docker).~~  
        ~~* Test and Save.~~  
* ~~**Features**:~~  
    ~~* Consolidates notifications for multiple episodes from the same series imported close together.~~  
    ~~* Uses Sonarr's v3 API.~~  
    ~~* Telegram notifications.~~  
    ~~* Self-update capability (`-u` or `--update`).~~  
    ~~* Manages a lockfile using PIDs to ensure sequential processing of notifications.~~  

---

### Sonarr Update TBA (`sonarr-update-tba.bash`)

* **Purpose**: Checks your Sonarr library for files that were imported with "TBA" titles and attempts to rename them by refreshing metadata once the actual episode titles are available. This script is intended to run on the host system, interacting with Sonarr running in Docker.
* **Requirements**:
    * Docker (if Sonarr is Dockerized)
    * Dependencies: `awk`, `curl`, `docker`, `jq`, `md5sum`
    * Sonarr setting "Episode Title Requires" should be set to "Only for Bulk Season Releases" or "Never" to allow importing TBA titled episodes.
* **Installation**:
    1.  Download the `.bash` script and the `.env.example` file to your host system.
    2.  Rename `sonarr-update-tba.env.example` to `sonarr-update-tba.env` and customize it with your Sonarr details.
    3.  Set the script to run via a cron job (e.g., hourly).
* **Features**:
    * Identifies files with "TBA" or "TBD" in their names within Sonarr's library paths.
    * Triggers a series refresh and then a rename command in Sonarr for the affected series/episodes.
    * Telegram and Discord notifications for renamed items or errors.
    * Self-update capability (`-u` or `--update`).
    * Supports multiple Sonarr instances if they are Docker-based; single host-based instance also supported.
    * Ignore lists for libraries, series, and episodes.
    * Manages a lockfile to prevent concurrent execution.

---

### Unifi Client Monitor (`unifi_client_monitor.bash`)

* **Purpose**: Monitors `/var/log/daemon.log` on a Unifi device (likely a UDM) for DHCPACK entries, logs new client connections to an SQLite database, and sends Telegram notifications for newly seen clients or MAC addresses.
* **Requirements**:
    * `yq` (will attempt to download if missing)
    * `sqlite3` (will attempt to `apt install` if missing)
    * Dependencies: `curl`, `date`, `sqlite3`, `yq`
* **Installation**:
    1.  Download the `.bash` script and `unifi_client_monitor.env.example`.
    2.  Rename `unifi_client_monitor.env.example` to `unifi_client_monitor.env` and customize with Telegram bot details and local DNS server IP.
    3.  Place both files in a suitable directory on your Unifi device.
    4.  Make the script executable: `chmod +x unifi_client_monitor.bash`.
    5.  Run the script; it will background itself to continuously monitor the log. Consider using [on-boot.d](https://github.com/unifi-utilities/unifios-utilities/tree/main/on-boot-script-2.x) for persistance.
* **Features**:
    * Continuously monitors `/var/log/daemon.log` for new DHCP leases.
    * Logs new client details (VLAN, MAC, IP, Name from DHCP, Timestamp) to an SQLite database (`.unifi_client_monitor.db`).
    * Sends a Telegram notification when a new client (or a known MAC with a new IP/VLAN) is detected.
    * Checks against a local DNS server for a hostname associated with the new IP address.
    * Indicates if the MAC address has been seen before.
    * Manages a lockfile to prevent concurrent execution of the main script (the monitoring part runs in the background).

---

### Update Plex in Docker (`update-plex-in-docker.bash`)

* **Purpose**: Automates the update process for official Plex Media Server Docker containers. It checks the currently running version against the latest available from Plex.tv and, if an update is found and no one is actively using Plex, restarts the container to apply the update.
* **Requirements**:
    * Docker
    * Dependencies: `awk`, `curl`, `docker`, `jq`, `md5sum`, `xmllint`
* **Installation**:
    1.  Download the `.bash` script and the `.env.example` file to your Docker host.
    2.  Rename `update-plex-in-docker.env.example` to `update-plex-in-docker.env` and customize with your Plex container name, access token, and other preferences.
    3.  Set the script to run via a cron job (e.g., hourly).
* **Features**:
    * Fetches the latest Plex version information from plex.tv.
    * Compares installed version with the latest available for the specified channel (plexpass, beta, public).
    * Checks for active Plex sessions and only proceeds with an update if the server is idle.
    * Optional database repair using ChuckPA's DBRepair.sh.
    * Clears the Plex Codecs directory before restarting to prevent potential issues.
    * Restarts the specified Plex Docker container to apply the update.
    * Telegram and Discord notifications for updates and errors.
    * Self-update capability (`-u` or `--Update`).
    * Manages a lockfile to prevent concurrent execution.

---

### YouTube to Podcast (`youtube_to_podcast.bash`)

* **Purpose**: Converts a YouTube playlist or channel into a podcast RSS feed, downloading audio using `yt-dlp` and generating the necessary XML.
* **Requirements**:
    * Dependencies: `awk`, `curl`, `date`, `ffprobe`, `md5sum`, `mimetype`, `qrencode`, `sha256sum`, `shuf`, `sqlite3`, `stat`, `xmllint`, `yq`, `yt-dlp`
* **Installation**:
    1.  Download the `.bash` script and the `.env.example` file.
    2.  Rename `youtube_to_podcast.env.example` to `youtube_to_podcast.env` and customize it with your YouTube API key, source URL, and desired podcast details.
    3.  Set the script to run via a cron job (e.g., hourly).
* **Features**:
    * Downloads audio from YouTube videos in a specified playlist or channel.
    * Generates a valid RSS feed (`feed.xml`) for use in podcast players.
    * Stores video metadata, download status, and file paths in an SQLite database (`.youtube_to_podcast.bash.db`).
    * Optional SponsorBlock integration to remove sponsored segments from downloaded audio.
    * Manages a configurable number of recent episodes to keep (`keepLimit`).
    * Extracts metadata such as titles, descriptions, and thumbnails from YouTube.
    * Calculates episode duration and file sizes for the RSS feed.
    * Telegram notifications for errors or successful runs.
    * Self-update capability (`-u` or `--update`).
    * Generates a QR code for the podcast feed URL on initial database setup if `qrencode` is available.
    * Manages a lockfile to prevent concurrent execution.

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
