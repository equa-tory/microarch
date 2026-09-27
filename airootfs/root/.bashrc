# microarch: source the synced dotfiles shellrc if present, else fall back
if [[ -r /root/.config/dotfiles/shellrc ]]; then
    . /root/.config/dotfiles/shellrc
else
    PS1='[\u@\h \W]\# '
fi

# scripts dropped in the dotfiles repo's bin/ are runnable anywhere, with
# no extra setup, as soon as they sync down
export PATH="$HOME/.config/dotfiles/bin:$PATH"
