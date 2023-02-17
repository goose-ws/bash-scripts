# bash-scripts

This is a collection of bash scripts I've hacked together over time which may be useful enough that I'm sharing them on GitHub

I have a moderate amount of skill in bash. I am no expert, but I am no novice either. There may be better ways to execute the flow of logic I am trying to achieve in these scripts. If you have a suggestion, I would welcome a pull request. If you have an issue, you are welcome to create an Issue or reach out to me on IRC. I idle in #goose on Libera, and usually respond within a few hours of being highlighted.

Unless otherwise noted, all scripts in this repository are covered by the [BSD 3 liencse](https://github.com/goose-ws/bash-scripts/blob/main/LICENSE)

These scripts will generally work by sourcing the "Config" options to a `.env` file with the same base file name, and kept in the same directory. So for example, if you want to use the `captive-dns.bash` script, you will need to place `captive-dns.env` in the same directory next to it. The config file names are dynamic to the script file name. So if you wanted to rename `captive-dns.bash` to `force-dns.bash`, then your config file would need to be `force-dns.env` in the same directory.

I will generally try and write in a `-h` or `--help` flag as well, that you can run scripts with to see what options they have.

Scripts here include:
* `captive-dns.bash` - A script meant for the UniFi Dream Machine line, which can be used to force DNS to a specific DNS server. This can be useful to force devices which ignore the DNS server handed out by DHCP to use the DNS server of your choice, such as a Google Home. The script will run every minute to ensure your configured DNS server is actually working, and switch to backup option(s) if it is not.
