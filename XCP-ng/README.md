# XCP-ng用script群

## xcp-ng-nic-offload.sh
Guest OSにFreeBSDなどを利用している時に、XCP-ng側のNIC設定でHardware offload機能を利用していると、通信が異常に遅くなることがある。これはTCPのChecksum計算の問題であることが多い。

毎回毎回いちいち細かく設定するのも面倒なので、一括でoffloadをoffにするscriptを書いた。

Usage: xcp-ng-nic-offload.sh [-del]
  -d : set TCP NIC offload disable.
  -e : set TCP NIC offload enable.
  -l : show current setting of other-config

これを実行すると、一気にVMやHyperVisorのNICのHardware offload設定のon/offを設定できる

# ssGetVMList.sh

## XCP-ng マルチプール・インベントリ収集script

### システム概要と基本方針

本システムは、複数のXCP-ngプール（プールマスター）からインベントリ情報を一括して安全に抽出し、可読性と管理性に優れた単一の統合管理表（CSV）として出力することを目的とします。
  * 出力フォーマット: CSV形式（カンマ区切り、すべてのフィールドをダブルクォーテーション " で囲む）
    * TSVにすることも検討中
  * 文字コード: UTF-8（ExcelやLibreOffice Calcでの文字化けを防ぐため、ファイルの先頭に BOM (\357\273\277) を付与）

# レコードの並び順（グループ化と階層構造）

インベントリとしての視認性を最大化するため、出力レコードの順序は以下の階層構造に厳格に統制されます。
  * PH (Physical Hypervisor): プール内のすべての物理ホスト行を先頭に配置。
  * CD (Control Domain): すべてのコントロール ドメイン行をその次に配置。
  * VM / SS (Virtual Machine & Snapshot): 通常VMを配置し、その直後の行に、そのVMから取得されたスナップショットを作成日時が古い順（昇順）で連続して配置。
  * 孤立スナップショット: 親VMが特定できないスナップショットは、リストの最末尾に [Orphan Snapshot] として集約。

# ネットワークカラムの動的ソート方針

プールごとに異なるネットワーク構成やVLAN設定を統一的に扱うため、動的ヘッダーの並び順は以下のルールで自動ソートされます。
  * Accessポート: VLANタグのないネットワークをデバイス番号・名称順に前半へ配置。
  * Trunkポート: VLANタグを持つネットワークを VLAN番号の昇順（数値順） で後半へ配置。

# マルチプール実装アーキテクチャと方針

  * 完全非同期・独立リモート収集層:
    * 各プールマスターに対して ssh（BatchMode=yes, ConnectTimeout=5）で接続し、リモート側で軽量なデータ抽出を完結させてタイムアウトやハングアップを防止。
  * 中間ファイル（TSV）キャッシュ層:
    * リモートから回収した生データは、オブジェクト種別（NET, PH, OBJ, VIF）のプレフィックス付きTSVとしてローカルへ一時保存。
  * インメモリ統合処理層（AWK）:
    * すべてのデータ回収後に POSIX awk へ一括投入し、メモリ上で結合・ソート・フォーマットを高速実行。
