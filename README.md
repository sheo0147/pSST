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
