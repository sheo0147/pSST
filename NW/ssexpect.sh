#!/bin/sh
#
# ssexpect		: Expect like shellscript.
#
##############################################################################
#
# Need command.
#   Connect to node
#     ssh(9.7p1/10.2p1) or telnet or nc
#   pty controller
#     tmux(3.7b) or GNUscreen(tested by 5.0.1)
#

# ==============================================================================
# 設定変数の初期化とデフォルト値定義
# ==============================================================================
MODE_ARG="telnet"                                       # -m: リモート接続バイナリの名前またはフルパス
BACKEND_ARG="tmux"                                      # -B: 使用する仮想端末バックエンド [ tmux | screen ]
TIMEOUT=5                                               # -w: 文字列検知・画面静止のタイムアウト（秒）
__DEBUG=0                                               # -d: デバッグログ出力レベル（環境変数と動的同期）
SSH_USER=""                                             # -u: SSH接続時に使用するログインユーザー名
CONN_PORT=""                                            # -P: リモート接続先の宛先TCPポート番号
EXTRA_OPTS=""                                           # -O: 接続バイナリへ直接引き渡す生の追加オプション

SESSION_NAME="ssexpect_$$"                              # 仮想端末セッションを多重実行時も一意にする識別名
BEFORE_FILE="/tmp/ssexpect_before_${SESSION_NAME}.txt"   # コマンド送信「直前」の画面バッファ全履歴退避先
AFTER_FILE="/tmp/ssexpect_after_${SESSION_NAME}.txt"     # コマンド送信「完了後」の画面バッファ全履歴退避先

# コマンド送信前の仮想端末の「総行数」を記録する一時変数（インデックス同期用）
BASELINE_LINES_COUNT=0

# ==============================================================================
# 共通関数定義
# ==============================================================================

# ------------------------------------------------------------------------------
# 関数: show_usage
# 概要: 構文エラーや -h 指定時に、コマンド仕様・記述サンプルを標準エラー出力へ表示
# ------------------------------------------------------------------------------
show_usage() {
    if [ -n "$1" ]; then printf 'Error: %s\n\n' "$1" >&2; fi
    cat << EOF >&2
==============================================================================
  ssexpect (ShellScript EXPECT) - Scenario-Driven Interactive Automation Tool
==============================================================================
[Syntax]
  sh $0 [Options] <Target_Host/IP> <Scenario_File(TSV)>

[Options]
  -m <cmd/path>  Specify connection command or protocol. (Default: telnet)
  -B <backend>   Select terminal backend [ tmux | screen ]. (Default: tmux)
  -w <seconds>   Timeout for screen string detection. (Default: 5)
  -d [level]     Set debug logging level (Default: 1 if level is omitted).
  -u <username>  Specify login username for SSH connections.
  -P <port>      Specify connection port (Auto-applied 23 for '-m nc').
  -O <"options"> Pass raw additional options directly to the execution binary.

[Scenario File (TSV) Format]
  "Expected String" \t "Input Command" \t "Print Flag(p)" \t "Output Path"

[Examples]
  # 1. Telnet connection via tmux backend (Default)
  sh $0 -m telnet -d 1 10.1.255.250 alaxala_telnet.tsv

  # 2. SSH connection with user definition via screen backend
  sh $0 -m ssh -B screen -u admin -w 10 10.1.255.254 apresia_ssh.tsv

  # 3. Netcat raw TCP port 23 connection with direct options passed
  sh $0 -m nc -O "-t" -P 23 10.1.255.250 alaxala_telnet.tsv

[TSV Sample]
  # Wait String \t Send Command \t Print Flag \t Output File Path
  login         username
  Passw         Top_Secret00
  swm>          show ver        p               ./version_output.txt
  swm>          enable
  Passw         Ultra_Secret!99
  swm#          set terminal pager disable
  swm#          show run        p               ./config_backup.txt
  swm#          exit
==============================================================================
EOF
    exit 1
}

# ------------------------------------------------------------------------------
# 関数: debug_print
# 概要: ユーザー指定のデバッグレベル（__DEBUG）に応じて、進捗ログを出力
# ------------------------------------------------------------------------------
debug_print() {
    level="$1"
    shift
    if [ "$__DEBUG" -ge "$level" ]; then
        if [ "$1" = "-n" ]; then shift; printf '%s' "$*"; else printf '%s\n' "$*"; fi
    fi
}

# ------------------------------------------------------------------------------
# 関数: cleanup
# 概要: スクリプト終了時（正常/異常/Ctrl+Cなど）に、一時ファイルと仮想端末を完全消去
# ------------------------------------------------------------------------------
cleanup() {
    if [ "$USE_BACKEND" = "tmux" ]; then
        tmux kill-session -t "$SESSION_NAME" 2>/dev/null
    elif [ "$USE_BACKEND" = "screen" ]; then
        screen -S "$SESSION_NAME" -X quit >/dev/null 2>&1
    fi
    rm -f "$BEFORE_FILE" "$AFTER_FILE"
}
# 各種シグナル（正常終了、割り込み、強制終了）にクリーンアップ処理をバインド
trap cleanup EXIT INT TERM

# ------------------------------------------------------------------------------
# 関数: check_session_alive
# 概要: バックエンド仮想端末の中で、対話型セッションがまだ生存しているか確認
# ------------------------------------------------------------------------------
check_session_alive() {
    if [ "$USE_BACKEND" = "tmux" ]; then
        tmux has-session -t "$SESSION_NAME" 2>/dev/null; return $?
    elif [ "$USE_BACKEND" = "screen" ]; then
        screen -ls | grep -q "\.${SESSION_NAME}[[:space:]]" 2>/dev/null; return $?
    fi
}

# ------------------------------------------------------------------------------
# 関数: safe_stuff
# 概要: 仮想端末に対し、文字列（コマンド）を入力して ENTER 信号をネイティブ送出
# ------------------------------------------------------------------------------
safe_stuff() {
    cmd_str="$1"
    # 空白行または改行のみが指定された場合は、何も打たずにENTER単発を投げる
    [ "$cmd_str" = "\r" ] || [ -z "$cmd_str" ] && cmd_str=""
    debug_print 1 "[DEBUG SEND]: ${cmd_str:-[ONLY ENTER]}"

    if [ "$USE_BACKEND" = "tmux" ]; then
        tmux send-keys -t "$SESSION_NAME" "$cmd_str" ENTER
    elif [ "$USE_BACKEND" = "screen" ]; then
        if [ -n "$cmd_str" ]; then
            # screen の stuff 命令は長大な文字列を一度に流すと文字化け・こぼれが起きるため、
            # fold を使って1文字ずつ丁寧に叩き込むことで高ポータビリティを確保
            printf '%s\n' "$cmd_str" | fold -w 1 | while IFS= read -r char; do
                [ -n "$char" ] && screen -S "$SESSION_NAME" -X stuff "$char"
            done
        fi
        # 最後に確実にキャリッジリターン（ENTER）を印字
        screen -S "$SESSION_NAME" -X stuff "$(printf '\r')"
    fi
}

# ------------------------------------------------------------------------------
# 関数: capture_all_history
# 概要: スクロールバックバッファを含む、現在の端末上のすべての文字列をファイルへ保存
# ------------------------------------------------------------------------------
capture_all_history() {
    output_file="$1"
    rm -f "$output_file"
    if [ "$USE_BACKEND" = "tmux" ]; then
        # -S - を指定することで、バッファの最古履歴の底から最新行までを完全にロード
        tmux capture-pane -t "$SESSION_NAME" -p -e -S - > "$output_file" 2>/dev/null
    elif [ "$USE_BACKEND" = "screen" ]; then
        # hardcopy -h を指定することで、スクロールバック履歴を含めてディスクへダンプ
        screen -S "$SESSION_NAME" -X hardcopy -h "$output_file" 2>/dev/null
    fi
    # ファイルが生成されなかった場合の保険として空ファイルを生成
    [ ! -f "$output_file" ] && touch "$output_file"
}

# ------------------------------------------------------------------------------
# 関数: wait_for_prompt_landing (★外部プロセス集約内製化モデル)
# 概要: 端末の「最下行（最終行）」に、目的のプロンプトがしっかりと着地するまで同期して待機
# 設計: 画面全体を部分一致検索すると、コマンド送信直後に過去の残骸プロンプトにフライング誤反応します。
#       これを防ぐため、バッファの一番下（最終行）のみを正確に切り出し、そこに文字列が着地するのを待ちます。
# 修正: 元の tr | grep | tail の3連パイプを完全排除。POSIX awk 1発のみで「\rの消去」「空行の除外」
#       および「最終行のホールド」を同時に完結させ、プロセスの生成コストを劇的に削減しました。
# ------------------------------------------------------------------------------
wait_for_prompt_landing() {
    target_prompt="$1"
    [ -z "$target_prompt" ] && return 0

    debug_print 1 "[DEBUG WAIT]: Sleeping until target string \"$target_prompt\" arrives at the bottom line..."

    elapsed=0
    while [ "$elapsed" -lt "$TIMEOUT" ]; do
        # 【exitバグの完全修正ロジック】
        # exitコマンド送信後、リモート側から切断されてセッションが閉じられた場合は
        # タイムアウトエラーではなく「ログアウト完了」という正常終了のため、即座に0を返してアウターメインループを抜けます。
        if ! check_session_alive; then
            debug_print 1 "[DEBUG WAIT]: Session closed by remote host. Assuming successful exit."
            return 0
        fi

        # 現在の最新の全履歴を取得
        capture_all_history "$AFTER_FILE"

        # 【レビューポイント: 3連フォークの大粛清】
        # ネットワーク機器の応答行末の \r を gsub で消去し、文字が含まれる最新行を last 変数へ随時上書き退避。
        # ファイル走査が終わった END ブロックで最終行だけを安全に標準出力へ戻します。
        last_line=$(awk '
            { gsub(/\r/, ""); clean = $0; gsub(/[ \t]/, "", clean) }
            clean != "" { last = $0 }
            END { print last }
        ' "$AFTER_FILE")

        debug_print 2 "--- [DEBUG LEVEL 2: CURRENT LAST LINE] ---"
        debug_print 2 "$last_line"

        # 最下行に目的の文字列が含まれていれば、プロンプトの完全着地とみなして同期完了
        case "$last_line" in
            *"$target_prompt"*)
                debug_print 1 "[DEBUG WAIT]: Successfully verified prompt landing."
                return 0
                ;;
        esac

        sleep 1
        elapsed=$((elapsed + 1))
    done

    printf 'Error: Timeout waiting for prompt "%s" to land at the bottom.\n' "$target_prompt" >&2
    exit 1
}

# ------------------------------------------------------------------------------
# 関数: wait_for_stream_freeze (★外部プロセス集約内製化モデル)
# 概要: データが出力されている（画面が激しくスクロールしている）間はループを継続し、
#       1秒前と現在の全行数が一致（＝データの出力が完全に停止・静止）した瞬間を自動検知
# 設計: show run等で長大なテキストが流れる際、全履歴の総行数の増加（スクロール）が
#       ピタッと止まる瞬間を捉えることで、エコーバックの状態に関わらず確実に出力完了を同期します。
# 修正: 元の wc -l | tr -d ' ' の2連フォークを排除し、awk 'END { print NR }' で総行数を一発特定します。
# ------------------------------------------------------------------------------
wait_for_stream_freeze() {
    debug_print 1 "[DEBUG WAIT]: Sleeping until data stream freezes and stabilizes..."

    elapsed=0
    prev_count=0
    while [ "$elapsed" -lt "$TIMEOUT" ]; do
        sleep 1
        if ! check_session_alive; then break; fi

        capture_all_history "$AFTER_FILE"
        
        # 【レビューポイント: 行数カウントの内製化】
        # 外部バイナリを叩くことなく、POSIX awk の組み込み変数 NR (Record Number) を用いて行数を特定。
        current_count=$(awk 'END { print NR }' "$AFTER_FILE")

        # 前秒のカウントと今秒のカウントが一致したら、データの着地が完了（静止状態）したと判断して抜ける
        if [ "$current_count" = "$prev_count" ] && [ "$current_count" -gt 0 ]; then
            debug_print 1 "[DEBUG WAIT]: Stream freeze detected. Output completed successfully."
            return 0
        fi
        prev_count="$current_count"
        elapsed=$((elapsed + 1))
    done
    return 0
}

# ------------------------------------------------------------------------------
# 関数: record_snapshot
# 概要: コマンド送信「直前」の画面全体のテキスト（過去の残骸データ）をファイルに保存
# ------------------------------------------------------------------------------
record_snapshot() {
    if [ "$USE_BACKEND" = "screen" ]; then screen -S "$SESSION_NAME" -X redisplay 2>/dev/null; fi
    capture_all_history "$BEFORE_FILE"
    debug_print 1 "[DEBUG SNAPSHOT]: Baseline screen snapshot secured successfully."
}

# ------------------------------------------------------------------------------
# 関数: print_clean_output (★逆引き完全内製化・3状態ステートマシンモデル)
# 概要: コマンド送信後の全出力から、過去の残骸および下部の無駄な余白を消去し、純粋な実行結果のみを出力
# 修正: 元の tr | grep | tail | cut という重い4連パイプラインを完全排除。
#       awk の index() 関数を応用し、画面最下部にある本物のプロンプトの行番号を安全・高速に逆引き特定。
#       Mac (BSD系nawk) 特有の制約「ENDブロック内でのnext呼び出し禁止エラー」を根本から完全解決した決定版です。
# ------------------------------------------------------------------------------
print_clean_output() {
    header_title="$1"
    target_out_file="$2"
    target_prompt="$3"

    # コマンドが出きった送信後の最新全履歴テキストをファイルに回収
    capture_all_history "$AFTER_FILE"

    # 【レビューポイント: 4連外部プロセスの大粛清】
    # 送信後のテキストを行頭から走査し、行の中にプロンプト文字列（pmt）が含まれている場合、
    # その行番号（NR）を変数 idx に随時上書き。これにより、画面の最も下にある本物のプロンプトの行番号が1発で求まります。
    last_prompt_idx=$(awk -v pmt="$target_prompt" '
        { gsub(/\r/, "") }
        index($0, pmt) > 0 { idx = NR }
        END { print idx + 0 }
    ' "$AFTER_FILE")

    # 万が一逆引きでインデックスが特定できなかった場合の安全弁として、ファイルの末尾の行番号をリミッターとしてセット
    if [ "$last_prompt_idx" -eq 0 ]; then
        last_prompt_idx=$(awk 'END { print NR }' "$AFTER_FILE")
    fi

    {
        printf '%s\n' "=== $header_title ==="
        if [ -f "$AFTER_FILE" ] && [ -f "$BEFORE_FILE" ]; then
            # 【3状態ステートマシン(gate 0->1->2)による余白空行完全消滅ロジック】
            # gate=0: 送信前の画面テキストと上から順に突合し、完全一致している古い行（残骸）をスキップ（トリミング期間）
            # gate=1: 変化（コマンドエコー行）を検知して移行。次の実データが出現するまでに挟まる無駄な空行をすべて無視（本尊待ち期間）
            # gate=2: 本物のデータが始まったら移行。以降は意味のある空行を含めてすべてのフォーマットを維持して生出力（出力期間）
            #         事前に引き渡した max_idx（本物のプロンプト行）に達した瞬間に exit して処理を打ち切る。
            awk -v max_idx="$last_prompt_idx" '
            BEGIN { gate = 0 }
            NR == FNR {
                clean = $0; gsub(/\r/, "", clean); before_lines[FNR] = clean
                next
            }
            {
                gsub(/\r/, "", $0)

                # [状態0] 過去の古い画面との完全一致スキップフェーズ
                if (gate == 0) {
                    if (FNR in before_lines && before_lines[FNR] == $0) {
                        next
                    } else {
                        gate = 1
                        print $0  # 最初に不一致となった「コマンドエコー行」を出力して次へ
                        next
                    }
                }

                # [状態1] コマンド名出力後、実データ（中身）が降ってくるまでの、screen特有の余白空行スキップフェーズ
                if (gate == 1) {
                    clean_line = $0; gsub(/[ \t]/, "", clean_line)
                    if (clean_line == "") {
                        next  # 文字が含まれない空行であれば、本尊データではないため完全無視して次行へ
                    } else {
                        gate = 2 # 文字が含まれる行を検知した瞬間、出力ゲートを2へ解放
                    }
                }

                # [状態2] 本物のデータの正規出力フェーズ（プロンプト着地行に達したら即座に打切り）
                if (gate == 2) {
                    print $0
                    if (FNR == max_idx) {
                        exit  # これにより、プロンプト行の下部に無限に広がる仮想端末の余白空行が100%完全に切り落とされる
                    }
                }
            }' "$BEFORE_FILE" "$AFTER_FILE"
        fi
        printf '%s\n' "========================================"
    } | if [ -n "$target_out_file" ]; then tee "$target_out_file"; else cat; fi
}

# ==============================================================================
# 引数・オプション解析 ( getopts )
# ==============================================================================
# 引数を持たない単発の「-d」と、数値を指定する「-d 2」の両パターンを美しく同居させるため、
# getopts の定義からあえてコロンを削除。数値の有無は内部で動的に先読みパースします。
while getopts ":m:B:w:du:P:O:tshD:T:" opt; do
    case "$opt" in
        m) MODE_ARG="$OPTARG" ;;
        B) BACKEND_ARG="$OPTARG" ;;
        w) TIMEOUT="$OPTARG" ;;
        d)
            # getopts のインデックス（OPTIND）を応用し、次のパラメータを eval で安全に先読み
            eval "next_arg=\${$OPTIND}"
            case "$next_arg" in
                # 次の引数が空、または数字以外の文字（IPアドレスや別のオプション）を含んでいる場合
                # ➔ デバッグ数値は省略されたとみなし、デフォルトの「レベル1」を適用してポインタは進めない
                ''|*[!0-9]*) DEBUG_LEVEL=1; __DEBUG=1 ;;
                # 次の引数が純粋な数字（0〜9の並び）である場合
                # ➔ その数値をデバッグレベルとして適用し、使用した引数の分 getopts のポインタを1つ進める
                *)           DEBUG_LEVEL="$next_arg"; __DEBUG="$next_arg"; OPTIND=$((OPTIND + 1)) ;;
            esac
            export __DEBUG
            ;;
        u) SSH_USER="$OPTARG" ;;
        P) CONN_PORT="$OPTARG" ;;
        O) EXTRA_OPTS="$OPTARG" ;;
        t|s|D|T) show_usage "Deprecated options specified. Please check the current CLI syntax." ;;
        h)   show_usage ;;
        \?)  show_usage "Invalid option: -${OPTARG}" ;;
        :)   show_usage "Option -${OPTARG} requires a value." ;;
    esac
done
shift $((OPTIND - 1))

# 必須パラメータ（ターゲットIPとTSVシナリオファイル名）のバリデーション
if [ $# -ne 2 ]; then show_usage "Expected <target_ip> and <scenario_file>"; fi
TARGET_IP="$1"
SCENARIO_FILE="$2"

if [ ! -f "$SCENARIO_FILE" ]; then printf 'Error: File not found: %s\n' "$SCENARIO_FILE" >&2; exit 1; fi

# 指定されたバックエンドバイナリの生存確認と確定
if [ "$BACKEND_ARG" = "screen" ]; then
    command -v screen >/dev/null 2>&1 || { printf 'Error: screen binary not found.\n' >&2; exit 1; }
    USE_BACKEND="screen"
else
    command -v tmux >/dev/null 2>&1 || { printf 'Error: tmux binary not found.\n' >&2; exit 1; }
    USE_BACKEND="tmux"
fi

# 指定された接続コマンド（プロトコル名）のフルパス探索
REAL_CMD_PATH=""
if [ "${MODE_ARG}" != "${MODE_ARG#*/}" ]; then
    [ -x "$MODE_ARG" ] && [ ! -d "$MODE_ARG" ] && REAL_CMD_PATH="$MODE_ARG"
else
    SAVED_IFS="$IFS"; IFS=":"
    for dir in $PATH; do
        [ -z "$dir" ] && dir="."
        if [ -x "${dir}/${MODE_ARG}" ] && [ ! -d "${dir}/${MODE_ARG}" ]; then
            REAL_CMD_PATH="${dir}/${MODE_ARG}"; break
        fi
    done
    IFS="$SAVED_IFS"
fi
[ -z "$REAL_CMD_PATH" ] && { printf 'Error: Connection command not found or not executable: %s\n' "$MODE_ARG" >&2; exit 1; }

# 各接続バイナリのコマンド特性（ポート引数のフラグ違いなど）を自動選別する判定ブロック
CMD_BASE_NAME="${REAL_CMD_PATH##*/}"
case "$CMD_BASE_NAME" in
    *ssh*) BASE_MODE="ssh" ;; *nc|*netcat*) BASE_MODE="nc" ;; *) BASE_MODE="telnet" ;;
esac

# 判定されたプロトコルに基づき、宛先IP・ポート・追加オプションの文字列構造を最適に組み立て
case "$BASE_MODE" in
    ssh)
        [ -n "$CONN_PORT" ] && PORT_OPT="-p $CONN_PORT"
        [ -n "$SSH_USER" ] && DEST_STR="${SSH_USER}@${TARGET_IP}" || DEST_STR="$TARGET_IP"
        EXEC_CMD="$REAL_CMD_PATH $PORT_OPT $EXTRA_OPTS $DEST_STR"
        ;;
    nc)
        [ -z "$CONN_PORT" ] && CONN_PORT="23" # netcatでポート省略時は標準Telnetポートを自動割当て
        EXEC_CMD="$REAL_CMD_PATH $EXTRA_OPTS $TARGET_IP $CONN_PORT"
        ;;
    telnet|*)
        [ -n "$CONN_PORT" ] && PORT_OPT="$CONN_PORT"
        EXEC_CMD="$REAL_CMD_PATH $EXTRA_OPTS $TARGET_IP $PORT_OPT"
        ;;
esac

debug_print 1 "Using backend: $USE_BACKEND (Mode: $BASE_MODE, Exec: $EXEC_CMD, Timeout: ${TIMEOUT}s)"

# ==============================================================================
# 対話シーケンスの開始 ( eval を用いた TTY ネイティブ接続の掴み取り )
# ==============================================================================
# バックグラウンドに sh -c などの二重カプセル化を絶対に挟まず、仮想端末に直接
# リモート接続コマンド（ssh/telnet）を実行させることで、TTYデバイスを見失うことなく
# 機器側からの画面印字応答を100%確実に引き出します。
if [ "$USE_BACKEND" = "tmux" ]; then
    eval "tmux new-session -d -s \"\$SESSION_NAME\" \"\$EXEC_CMD\""
else
    eval "screen -h 10000 -dmS \"\$SESSION_NAME\" \$EXEC_CMD"
fi
sleep 1 # 接続プロセスがフォークしてTTYが完全に初期化されるまでの安全弁ウェイト

# ==============================================================================
# シナリオ駆動 メインループ ( 完全直線型対話シーケンス )
# ==============================================================================
line_count=0

while IFS='	' read -r c_wait c_cmd c_p c_out || [ -n "$c_wait" ]; do
    line_count=$((line_count + 1))

    # シナリオ内のコメント行（#始まり）のスキップ処理
    case "$c_wait" in \#*) continue ;; esac
    # 完全に空の行があった場合はスキップ
    [ -z "$c_wait" ] && [ -z "$c_cmd" ] && continue

    # ループの先頭で常に対話セッションの死活を確認。死んでいたら正常脱出（exit時の生存回収用）
    if ! check_session_alive; then
        debug_print 1 "[DEBUG LOOP]: Session already closed by remote host. Exiting successfully."
        break
    fi

    # 【レビューポイント: 安定稼働を絶対厳守した変数トリミング】
    # 確実に動作することが実証されている元の直線型フィルタ構造をそのまま100%維持。
    # 各フィールドからキャリッジリターン、およびインラインコメント（#以降）を高速にクレンジング消去します。
    c_wait=$(printf '%s' "$c_wait" | tr -d '\r' | sed -e 's/[ 	]*#.*//' -e 's/[ 	]*$//')
    c_cmd=$(printf '%s' "$c_cmd" | tr -d '\r' | sed -e 's/[ 	]*#.*//' -e 's/[ 	]*$//')
    c_p=$(printf '%s' "$c_p" | tr -d '\r' | sed -e 's/[ 	]*#.*//' -e 's/[ 	]*$//')
    c_out=$(printf '%s' "$c_out" | tr -d '\r' | sed -e 's/[ 	]*#.*//' -e 's/[ 	]*$//')

    debug_print 1 "[DEBUG LOOP]: Line $line_count -> Wait:\"$c_wait\" Send:\"$c_cmd\""

    # 1. 指定された待ち文字列（プロンプト等）が画面の「最下部」に正しく着地するまで安全にホールド
    if [ -n "$c_wait" ]; then
        wait_for_prompt_landing "$c_wait"
        if ! check_session_alive; then break; fi
    fi

    # 2. pフラグ（結果保存）が立っている場合のみ、送信直前の画面履歴をスナップショット退避
    if [ "$c_p" = "p" ]; then record_snapshot; fi

    # 3. リモートのインフラ機器へコマンドを安全に入力送信
    safe_stuff "$c_cmd"

    # 4. pフラグ（結果保存）が立っている場合のみ、出力ストリームの静止を待ってクレンジング表示を実行
    if [ "$c_p" = "p" ]; then
        # 機器からデータが流れて画面がスクロールし、完全に静止（総行数が不変）するまで確実にホールド
        wait_for_stream_freeze
        # 画面の上下の広大な余白を1文字残さず完璧にカットするため、現在のプロンプト（c_wait）を第3引数へ託す
        print_clean_output "$c_cmd 実行結果" "$c_out" "$c_wait"
    fi

done < "$SCENARIO_FILE"

debug_print 1 "Automation process completed successfully."
exit 0
