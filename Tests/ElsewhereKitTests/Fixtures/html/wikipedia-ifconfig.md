# ifconfig - Wikipedia

Not to be confused with [ipconfig](https://en.wikipedia.org/wiki/Ipconfig).

| ifconfig |  |
|---|---|
| [![](https://thumb.wikimedia.org/wikipedia/commons/thumb/c/c9/Ifconfig_example_screenshot.png/250px-Ifconfig_example_screenshot.png?utm_source=en.wikipedia.org&utm_campaign=parser&utm_content=thumbnail)](https://en.wikipedia.org/wiki/File:Ifconfig_example_screenshot.png) Screenshot of ifconfig output in Linux |  |
| Release | August 1983; 43 years ago |
| [Operating system](https://en.wikipedia.org/wiki/Operating_system) | [Unix](https://en.wikipedia.org/wiki/Unix) and [Unix-like](https://en.wikipedia.org/wiki/Unix-like) |
| [Type](https://en.wikipedia.org/wiki/Software_categories#Categorization_approaches) | [Command](https://en.wikipedia.org/wiki/Command_(computing)) |

**ifconfig** (short for *interface configuration*) is a system administration utility in [Unix-like](https://en.wikipedia.org/wiki/Unix-like) operating systems for [network interface](https://en.wikipedia.org/wiki/Network_interface_controller) configuration.

The utility is a [command-line interface](https://en.wikipedia.org/wiki/Command-line_interface) tool and is also used in the system [startup scripts](https://en.wikipedia.org/wiki/Startup_script) of many operating systems. It has features for configuring, controlling, and querying [TCP/IP](https://en.wikipedia.org/wiki/TCP/IP) network interface parameters. ifconfig originally appeared in [4.2BSD](https://en.wikipedia.org/wiki/4.2BSD) as part of the [BSD](https://en.wikipedia.org/wiki/BSD) TCP/IP suite.

Many Linux distributions have deprecated ifconfig in favor of the [iproute2](https://en.wikipedia.org/wiki/Iproute2) tool suite.

## Usage

[[edit](https://en.wikipedia.org/w/index.php?title=Ifconfig&action=edit&section=1)]

Common uses for ifconfig include setting the [IP address](https://en.wikipedia.org/wiki/IP_address) and [subnet mask](https://en.wikipedia.org/wiki/Subnet_mask) of a network interface and disabling or enabling an interface.[1] At boot time, many Unix-like operating systems initialize their network interfaces with [shell scripts](https://en.wikipedia.org/wiki/Shell_script) that call ifconfig. As an interactive tool, system administrators routinely use the utility to display and analyze network interface parameters. The following two examples show the output of the tool when querying the state of a single active interface each on a [Linux](https://en.wikipedia.org/wiki/Linux)-based host (interface [eth](https://en.wikipedia.org/wiki/Ethernet)0) and the [ural0](https://en.wikipedia.org/wiki/Ralink) interface on an [OpenBSD](https://en.wikipedia.org/wiki/OpenBSD) installation.

```
 eth0      Link encap:Ethernet  HWaddr 00:0F:20:CF:8B:42
           inet addr:192.168.1.128  Bcast:  Mask:255.255.255.192
           UP BROADCAST RUNNING MULTICAST  MTU:1500  Metric:1
           RX packets:2472694671 errors:1 dropped:0 overruns:0 frame:0
           TX packets:44641779 errors:0 dropped:0 overruns:0 carrier:0
           collisions:0 txqueuelen:1000
           RX bytes:1761467179 (1679.7 Mb)  TX bytes:2870928587 (2737.9 Mb)
           Interrupt:28
```

```
 ural0: flags=8843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> mtu 1500
         lladdr 00:0d:0b:ed:84:fb
         media: IEEE802.11 DS2 mode 11b hostap (autoselect mode 11b hostap)
         status: active
         ieee80211: nwid ARK chan 11 bssid 00:0d:0b:ed:84:fb  100dBm
         inet 172.30.50.1 netmask 0xffffff00 broadcast 172.30.50.255
         inet6 fe80::20d:bff:feed:84fb%ural0 prefixlen 64 scopeid 0xa
```

- HWaddr: *hardware address*, [MAC address](https://en.wikipedia.org/wiki/MAC_address).
- The parameter *txqueuelen* is measured in number of [Ethernet frames](https://en.wikipedia.org/wiki/Ethernet_frame) and is the size of the buffer that is being managed by the [network scheduler](https://en.wikipedia.org/wiki/Network_scheduler).

### Medium access control functions

[[edit](https://en.wikipedia.org/w/index.php?title=Ifconfig&action=edit&section=2)]

ifconfig is also commonly used to change the [medium access control](https://en.wikipedia.org/wiki/Medium_access_control) (MAC) address of an interface. In this process, the network interface is first disabled (set *down*) with the ifconfig command, followed by a MAC change command:

```
ifconfig wlan0 down
ifconfig wlan0 hw ether 13:11:20:33:49:66
ifconfig wlan0 up
```

## Release status

[[edit](https://en.wikipedia.org/w/index.php?title=Ifconfig&action=edit&section=3)]

The [Berkeley Software Distribution](https://en.wikipedia.org/wiki/Berkeley_Software_Distribution) [UNIX](https://en.wikipedia.org/wiki/UNIX) operating systems (e.g., [NetBSD](https://en.wikipedia.org/wiki/NetBSD), [OpenBSD](https://en.wikipedia.org/wiki/OpenBSD), and [FreeBSD](https://en.wikipedia.org/wiki/FreeBSD)) continue active development of ifconfig and extension of its functionality to cover the configuration of [wireless networking](https://en.wikipedia.org/wiki/Wireless_network) interfaces, [VLAN](https://en.wikipedia.org/wiki/VLAN) trunking, controlling hardware features such as [TSO](https://en.wikipedia.org/wiki/TCP_segmentation_offloading) or hardware checksumming or setting up bridge and tunnel interfaces. [Solaris](https://en.wikipedia.org/wiki/Solaris_(operating_system)) has historically used ifconfig for all network interface configuration, but as of Solaris 10 introduced dladm to perform data-link (OSI model layer 2) configuration, reducing ifconfig's purview to IP configuration.

In older [Linux distributions](https://en.wikipedia.org/wiki/Linux_distribution), ifconfig, in conjunction with the utility [route](https://en.wikipedia.org/wiki/Route_(command)), was used to connect a computer to a network, and to define routes between networks. ifconfig for Linux is part of the package *net-tools*, released as the latest version 2.10 on 7 January 2021.[2]

Many Linux distributions have deprecated the use of ifconfig and route in favor of the software suite [iproute2](https://en.wikipedia.org/wiki/Iproute2), such as ArchLinux[3] or RHEL since version 7,[4] which has been available since 1999 for Linux 2.2.[5] iproute2 includes support for all common functions of ifconfig(8), route(8), arp(8) and netstat(1). It also includes multicast configuration support, tunnel and virtual link management, traffic control, and low-level IPsec configuration, among other features.

## Related tools

[[edit](https://en.wikipedia.org/w/index.php?title=Ifconfig&action=edit&section=4)]

Another higher-level Linux command line tool is **ifup** (including **ifdown** and **ifquery**). In addition to controlling the interfaces, it also provides control of other aspects of the network such as specifying the [DNS servers](https://en.wikipedia.org/wiki/DNS_server) to use. The command is configured using the file */etc/network/interfaces*, which contains "stanzas" for each interface.

[NetworkManager](https://en.wikipedia.org/wiki/NetworkManager) is a Linux daemon that automatically reconfigures the network in dynamic environments, such as moving between WiFi hotspots. It is usually used in conjunction with a graphical front-end such as [GNOME Shell](https://en.wikipedia.org/wiki/GNOME_Shell).

Versions of [Microsoft Windows](https://en.wikipedia.org/wiki/Microsoft_Windows) from [Windows 95](https://en.wikipedia.org/wiki/Windows_95) to [Windows Me](https://en.wikipedia.org/wiki/Windows_Me) used [winipcfg](https://en.wikipedia.org/wiki/Winipcfg) to give a graphical display of current IP information. [ipconfig](https://en.wikipedia.org/wiki/Ipconfig), a command similar to ifconfig, comes with [Microsoft](https://en.wikipedia.org/wiki/Microsoft) [operating-systems](https://en.wikipedia.org/wiki/Operating_system) based on the [Windows NT](https://en.wikipedia.org/wiki/Windows_NT) [kernel](https://en.wikipedia.org/wiki/Kernel_(operating_system)). [ipconfig](https://en.wikipedia.org/wiki/Ipconfig) also controls the Windows [DHCP](https://en.wikipedia.org/wiki/DHCP) [client](https://en.wikipedia.org/wiki/Client_(computing)).

In [macOS](https://en.wikipedia.org/wiki/MacOS), the ifconfig command functions as a [wrapper](https://en.wikipedia.org/wiki/Wrapper_pattern) to the IPConfiguration agent, and can control the [BootP](https://en.wikipedia.org/wiki/BootP) and DHCP clients from the command-line. Use of ifconfig to modify network settings in Mac OS X is discouraged, because ifconfig operates below the level of the system frameworks which help manage network configuration.

[iwconfig](https://en.wikipedia.org/wiki/Iwconfig), a component of [Wireless tools for Linux](https://en.wikipedia.org/wiki/Wireless_tools_for_Linux), which took its name from ifconfig, manages [wireless network](https://en.wikipedia.org/wiki/Wireless_network) interfaces outside the original scope of Linux's ifconfig. iwconfig sets such specialized settings as a wireless network's [SSID](https://en.wikipedia.org/wiki/SSID) and [WEP](https://en.wikipedia.org/wiki/Wired_Equivalent_Privacy) keys, and functions in tandem with [iwlist](https://en.wikipedia.org/wiki/Iwlist). Linux also features [iwspy](https://en.wikipedia.org/wiki/Iwspy), to read the signal, noise and quality of a wireless connection.

Other related tools for configuring Ethernet adapters are: [ethtool](https://en.wikipedia.org/wiki/Ethtool), [mii-tool](https://en.wikipedia.org/wiki/Mii-tool), and [mii-diag](https://en.wikipedia.org/wiki/Mii-diag?action=edit&redlink=1) in Linux and the command *[dladm](https://en.wikipedia.org/wiki/Dladm?action=edit&redlink=1) show-link* in Solaris.

The ip suite has a similar purpose and is meant to replace the [deprecated](https://en.wikipedia.org/wiki/Deprecated) ifconfig.[6]

## See also

[[edit](https://en.wikipedia.org/w/index.php?title=Ifconfig&action=edit&section=5)]

- [Consistent Network Device Naming](https://en.wikipedia.org/wiki/Consistent_Network_Device_Naming)
- [Ipconfig](https://en.wikipedia.org/wiki/Ipconfig)
- [Iproute2](https://en.wikipedia.org/wiki/Iproute2)

## References

[[edit](https://en.wikipedia.org/w/index.php?title=Ifconfig&action=edit&section=6)]

1. ↑ "Interface Configuration for IP". [*Linux Network Administrators Guide*](https://www.oreilly.com/openbook/linag2/book/ch05.html). June 2000. Retrieved 12 March 2024.
2. ↑ [net-tools](https://sourceforge.net/projects/net-tools/) on [SourceForge](https://en.wikipedia.org/wiki/SourceForge)
3. ↑ Gundersen, Tom (8 June 2011). ["News: Deprecation of net-tools"](https://www.archlinux.org/news/deprecation-of-net-tools/). Retrieved 28 March 2019.
4. ↑ Jonathan Corbet (4 January 2017). ["Moving on from net-tools"](https://lwn.net/Articles/710533/). [LWN.net](https://en.wikipedia.org/wiki/LWN.net). Retrieved 23 September 2019.
5. ↑ Litvak, Michail (6 March 2019). ["ip(8) manual page"](http://man7.org/linux/man-pages/man8/ip.8.html#HISTORY). Retrieved 28 March 2019.
6. ↑ Carrigan, Tyler (6 May 2020). ["Linux networking: ifconfig versus ip | Enable Sysadmin"](https://www.redhat.com/sysadmin/ifconfig-vs-ip). *[Red Hat](https://en.wikipedia.org/wiki/Red_Hat)*. Retrieved 2 November 2022.

## External links

[[edit](https://en.wikipedia.org/w/index.php?title=Ifconfig&action=edit&section=7)]

- [ifconfig(8)](https://net-tools.sourceforge.net/man/ifconfig.8.html), official [manpage](https://en.wikipedia.org/wiki/Manpage) for Linux net-tools ifconfig
- [ifconfig(8)](https://www.freebsd.org/cgi/man.cgi?query=ifconfig), manpage for the [FreeBSD](https://en.wikipedia.org/wiki/FreeBSD) ifconfig
- [ifconfig(8)](https://docs.oracle.com/cd/E19253-01/816-5166/ifconfig-1m/index.html), manpage for the [Solaris](https://en.wikipedia.org/wiki/Solaris_(operating_system)) ifconfig

| [v](https://en.wikipedia.org/wiki/Template:Unix_commands) [t](https://en.wikipedia.org/wiki/Template_talk:Unix_commands) [e](https://en.wikipedia.org/wiki/Special:EditPage/Template:Unix_commands) [Unix](https://en.wikipedia.org/wiki/Unix) [command-line](https://en.wikipedia.org/wiki/Command-line_interface) [utilities](https://en.wikipedia.org/wiki/Utility_software) and [shell builtins](https://en.wikipedia.org/wiki/Shell_builtin) |  |
|---|---|
| File system | [cat](https://en.wikipedia.org/wiki/Cat_(Unix)) [chattr](https://en.wikipedia.org/wiki/Chattr) [chmod](https://en.wikipedia.org/wiki/Chmod) [chown](https://en.wikipedia.org/wiki/Chown) [chgrp](https://en.wikipedia.org/wiki/Chgrp) [cksum](https://en.wikipedia.org/wiki/Cksum) [cmp](https://en.wikipedia.org/wiki/Cmp_(Unix)) [cp](https://en.wikipedia.org/wiki/Cp_(Unix)) [dd](https://en.wikipedia.org/wiki/Dd_(Unix)) [du](https://en.wikipedia.org/wiki/Du_(Unix)) [df](https://en.wikipedia.org/wiki/Df_(Unix)) [file](https://en.wikipedia.org/wiki/File_(command)) [fuser](https://en.wikipedia.org/wiki/Fuser_(Unix)) [ln](https://en.wikipedia.org/wiki/Ln_(Unix)) [ls](https://en.wikipedia.org/wiki/Ls) [mkdir](https://en.wikipedia.org/wiki/Mkdir) [mv](https://en.wikipedia.org/wiki/Mv_(Unix)) [pax](https://en.wikipedia.org/wiki/Pax_(command)) [pwd](https://en.wikipedia.org/wiki/Pwd) [rm](https://en.wikipedia.org/wiki/Rm_(Unix)) [rmdir](https://en.wikipedia.org/wiki/Rmdir) [split](https://en.wikipedia.org/wiki/Split_(Unix)) [tee](https://en.wikipedia.org/wiki/Tee_(command)) [touch](https://en.wikipedia.org/wiki/Touch_(command)) [type](https://en.wikipedia.org/wiki/Type_(Unix)) [umask](https://en.wikipedia.org/wiki/Umask) |
| Processes | [at](https://en.wikipedia.org/wiki/At_(command)) [bg](https://en.wikipedia.org/wiki/Job_control_(Unix)#Commands) [crontab](https://en.wikipedia.org/wiki/Cron) [fg](https://en.wikipedia.org/wiki/Job_control_(Unix)#Commands) [kill](https://en.wikipedia.org/wiki/Kill_(command)) [nice](https://en.wikipedia.org/wiki/Nice_(Unix)) [ps](https://en.wikipedia.org/wiki/Ps_(Unix)) [time](https://en.wikipedia.org/wiki/Time_(Unix)) |
| User environment | [env](https://en.wikipedia.org/wiki/Env) [exit](https://en.wikipedia.org/wiki/Exit_(command)) [logname](https://en.wikipedia.org/wiki/Logname) [mesg](https://en.wikipedia.org/wiki/Mesg) [talk](https://en.wikipedia.org/wiki/Talk_(software)) [tput](https://en.wikipedia.org/wiki/Tput) [uname](https://en.wikipedia.org/wiki/Uname) [who](https://en.wikipedia.org/wiki/Who_(Unix)) [write](https://en.wikipedia.org/wiki/Write_(Unix)) |
| Text processing | [awk](https://en.wikipedia.org/wiki/AWK) [basename](https://en.wikipedia.org/wiki/Basename) [comm](https://en.wikipedia.org/wiki/Comm) [csplit](https://en.wikipedia.org/wiki/Csplit) [cut](https://en.wikipedia.org/wiki/Cut_(Unix)) [diff](https://en.wikipedia.org/wiki/Diff) [dirname](https://en.wikipedia.org/wiki/Dirname) [ed](https://en.wikipedia.org/wiki/Ed_(text_editor)) [ex](https://en.wikipedia.org/wiki/Ex_(text_editor)) [fold](https://en.wikipedia.org/wiki/Fold_(Unix)) [head](https://en.wikipedia.org/wiki/Head_(Unix)) [iconv](https://en.wikipedia.org/wiki/Iconv) [join](https://en.wikipedia.org/wiki/Join_(Unix)) [m4](https://en.wikipedia.org/wiki/M4_(computer_language)) [more](https://en.wikipedia.org/wiki/More_(command)) [nl](https://en.wikipedia.org/wiki/Nl_(Unix)) [paste](https://en.wikipedia.org/wiki/Paste_(Unix)) [patch](https://en.wikipedia.org/wiki/Patch_(Unix)) [printf](https://en.wikipedia.org/wiki/Printf_(Unix)) [read](https://en.wikipedia.org/wiki/Read_(Unix)) [sed](https://en.wikipedia.org/wiki/Sed) [sort](https://en.wikipedia.org/wiki/Sort_(Unix)) [strings](https://en.wikipedia.org/wiki/Strings_(Unix)) [tail](https://en.wikipedia.org/wiki/Tail_(Unix)) [tr](https://en.wikipedia.org/wiki/Tr_(Unix)) [troff](https://en.wikipedia.org/wiki/Troff) [uniq](https://en.wikipedia.org/wiki/Uniq) [vi](https://en.wikipedia.org/wiki/Vi_(text_editor)) [wc](https://en.wikipedia.org/wiki/Wc_(Unix)) [xargs](https://en.wikipedia.org/wiki/Xargs) |
| [Shell builtins](https://en.wikipedia.org/wiki/Shell_builtin) | [alias](https://en.wikipedia.org/wiki/Alias_(command)) [cd](https://en.wikipedia.org/wiki/Cd_(command)) [echo](https://en.wikipedia.org/wiki/Echo_(command)) [test](https://en.wikipedia.org/wiki/Test_(Unix)) [unset](https://en.wikipedia.org/wiki/Environment_variable#unset_command) [wait](https://en.wikipedia.org/wiki/Wait_(command)) |
| Searching | [find](https://en.wikipedia.org/wiki/Find_(Unix)) [grep](https://en.wikipedia.org/wiki/Grep) |
| Documentation | [man](https://en.wikipedia.org/wiki/Man_page) |
| [Software development](https://en.wikipedia.org/wiki/Software_development) | [ar](https://en.wikipedia.org/wiki/Ar_(Unix)) [ctags](https://en.wikipedia.org/wiki/Ctags) [lex](https://en.wikipedia.org/wiki/Lex_(software)) [make](https://en.wikipedia.org/wiki/Make_(software)) [nm](https://en.wikipedia.org/wiki/Nm_(Unix)) [strip](https://en.wikipedia.org/wiki/Strip_(Unix)) [yacc](https://en.wikipedia.org/wiki/Yacc) |
| Miscellaneous | [bc](https://en.wikipedia.org/wiki/Bc_(programming_language)) [cal](https://en.wikipedia.org/wiki/Cal_(command)) [dc](https://en.wikipedia.org/wiki/Dc_(computer_program)) [expr](https://en.wikipedia.org/wiki/Expr) [lp](https://en.wikipedia.org/wiki/System_V_printing_system) [od](https://en.wikipedia.org/wiki/Od_(Unix)) [sleep](https://en.wikipedia.org/wiki/Sleep_(command)) [true and false](https://en.wikipedia.org/wiki/True_and_false_(commands)) [watch](https://en.wikipedia.org/wiki/Watch_(command)) |
| ![](https://thumb.wikimedia.org/wikipedia/en/thumb/9/96/Symbol_category_class.svg/20px-Symbol_category_class.svg.png?utm_source=en.wikipedia.org&utm_campaign=parser&utm_content=thumbnail) **Categories** [Standard Unix programs](https://en.wikipedia.org/wiki/Category:Standard_Unix_programs) [Unix SUS2008 utilities](https://en.wikipedia.org/wiki/Category:Unix_SUS2008_utilities) ![](https://thumb.wikimedia.org/wikipedia/en/thumb/d/db/Symbol_list_class.svg/20px-Symbol_list_class.svg.png?utm_source=en.wikipedia.org&utm_campaign=parser&utm_content=thumbnail) **[List](https://en.wikipedia.org/wiki/List_of_POSIX_commands)** |  |

Retrieved from "[https://en.wikipedia.org/w/index.php?title=Ifconfig&oldid=1357443123](https://en.wikipedia.org/w/index.php?title=Ifconfig&oldid=1357443123)"

Source: https://en.wikipedia.org/wiki/Ifconfig
