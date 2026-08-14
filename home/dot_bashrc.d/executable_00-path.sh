# PATH の設定
# $HOME/.local/bin を PATH の先頭に追加し、ユーザーごとのコマンドを優先的に実行できるようにします。
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac

# npm グローバルパッケージのパス
export PATH="$HOME/.npm-global/bin:$PATH"
