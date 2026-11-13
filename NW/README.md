# Network関連ツール

## phcde.sh             : Ping Host and Check DNS Entry
対象にpingをうち、返答があったものに関してhostコマンドでDNS lookupをかけるためのscript。
生きているhostがDNSに登録されていることを確認するのに利用できる。

## ssexpect		: Expect like shellscript.

expectのような動作をする対話的ツールで、TCL/TKを利用する必要がないものが欲しかったので、作ってみた。
基本、POSIX shellで記述しているが、ssh、telnet, ncのいずれかとtmux、GNU screenのどちらかを必要とする。

### ssexpect (ShellScript EXPECT) - Scenario-Driven Interactive Automation Tool
  * [Syntax]
    * sh ssexpect [Options] <Target_Host/IP> <Scenario_File(TSV)>
  * [Options]
    * -m <cmd/path>  Specify connection command or protocol. (Default: telnet)
    * -B <backend>   Select terminal backend [ tmux | screen ]. (Default: tmux)
    * -w <seconds>   Timeout for screen string detection. (Default: 5)
    * -d [level]     Set debug logging level (Default: 1 if level is omitted).
    * -u <username>  Specify login username for SSH connections.
    * -P <port>      Specify connection port (Auto-applied 23 for '-m nc').
    * -O <"options"> Pass raw additional options directly to the execution binary.
  * [Scenario File (TSV) Format]
    * "Expected String" \t "Input Command" \t "Print Flag(p)" \t "Output Path"
  * [Examples]
    1. Telnet connection via tmux backend (Default)
      * sh ssexpect -m telnet -d 1 10.1.255.250 alaxala_telnet.tsv
    2. SSH connection with user definition via screen backend
      * sh ssexpect -m ssh -B screen -u admin -w 10 10.1.255.254 apresia_ssh.tsv
    3. Netcat raw TCP port 23 connection with direct options passed
      * sh ssexpect -m nc -O "-t" -P 23 10.1.255.250 alaxala_telnet.tsv

  * [TSV Sample]
  ```
# Wait String \t Send Command \t Print Flag \t Output File Path
login         username
Passw         Top_Secret00
swm>          show ver        p               ./version_output.txt
swm>          enable
Passw         Ultra_Secret!99
swm#          set terminal pager disable
swm#          show run        p               ./config_backup.txt
swm#          exit
```
