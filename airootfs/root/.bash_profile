# microarch: the console autologin and SSH both start bash as a login
# shell, which reads this file instead of .bashrc — bridge to it.
[[ -f ~/.bashrc ]] && . ~/.bashrc
