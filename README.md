# book000/dotfiles

```bash
sh -c "$(curl -fsSL get.chezmoi.io)" -- init --apply book000
cp ~/.gitconfig.local.example ~/.gitconfig.local
vim ~/.gitconfig.local
cp ~/.env.example ~/.env
vim ~/.env
```
