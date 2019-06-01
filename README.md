# pSST : personal Shell Script Tools

個人的に使っている落書きのようなshell scriptを管理するために、GitHUBに置きます。
利用に関してはご自由にどうぞ。

## ライセンス
ライセンスはいわゆる２条項BSDライセンスとします。

## 内容物
以下に、内容物を記載します。が、まともなドキュメントを書くほどの余裕はありませんから、自力で読んでいただければ。

### Network関連 (NW)
  * phcde.sh : Ping Host and Check DNS Entry.
    * 引数として与えた範囲のnodeに対してpingを実施
    * 各アドレスに関して逆引きと正引きを行い、一致しているかを出力する
    * `/bin/sh phcde.sh 192.0.2.1 255` とすると、192.0.2.1〜192.0.2.255 まで検査する
    * root権限で動作させるとICMP検査が若干早くなる
    * FreeBSDでのみ試験済み
    * BINDに同梱されているhostコマンドが必要
      * 全てのPlatformに存在するこの種のコマンドがない...のでhostコマンドを仮定
      * KnotDNS同梱のhostコマンド(khost)も対応したいが...

### Certificate関連 (Cert)
  * certupdate
    * PREMISE.txtを参照のこと

### Scripting Tools (Script)
  * parse_yaml
    * POSIX範囲で記述した、簡易YAMLパーサー
    * 完全な実装ではないが、YAMLをパースし、Shellの環境変数に登録することができる
    * FreeBSDでのみ試験済み
    * AWKとShellのみで実装されている
    * parse_yaml関数を定義してある
    * 2 space indentにのみ対応

### XCP-ng関連 (XCP-ng)
  * XCP-ngはXenServerから派生したXenServer互換実装
  * XCP-ngはそのPlatformにCentOSを利用しているため、本ツール群は例外的にXCP-ngのbash環境を仮定する。
  * xcp-ng-nic-offload.sh
    * いくつかのOSは、TCPのNICへのoffloadに問題を抱えており、この機能が利用されるとHangUpや以上な通信速度の低下が発生するなどの悪影響がある。
    * しかし、VMごとにこの機能をいちいち設定することは管理の手間を増すことにつながるため、一律にTCP NIC OffloadをDisableするためのscriptとして本scriptを作成した
    * 表示とDisableとEnableが実装されているが、Enableは試験をしていないので、Enableに関しては使う人は注意のこと
