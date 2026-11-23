# External SSD support for zsh. Installed at ~/Local/ssd/ssd.zsh, sourced from ~/.zshrc:
#   [[ -r ~/Local/ssd/ssd.zsh ]] && source ~/Local/ssd/ssd.zsh
# Part of SSD Monitor (AGENTS.md, section 8); install.sh copies it to ~/Local/ssd/.

# ssd-resume / ssd-off live on the internal disk, so they work while the SSD is unplugged.
export PATH="$HOME/Local/bin:$PATH"

# Re-enter the current folder after the SSD was remounted (replug or the initial swap):
# a shell otherwise stays attached to the folder that disappeared. Runs before every prompt
# and before every command, costs one stat. Does nothing while the SSD is unplugged.
_ssd_reenter_cwd() { [[ . -ef $PWD ]] || builtin cd -q -- "$PWD" 2>/dev/null; }
autoload -Uz add-zsh-hook
add-zsh-hook precmd _ssd_reenter_cwd
add-zsh-hook preexec _ssd_reenter_cwd

# Keep the bun cache on the SSD's Repo volume while it is mounted, so `bun install` in ~/Repo
# makes APFS clones (same volume) instead of full copies. (This Mac's choice: drop or adapt elsewhere.)
[[ -d $HOME/Repo/.cache/bun ]] && export BUN_INSTALL_CACHE_DIR=$HOME/Repo/.cache/bun
