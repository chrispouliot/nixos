Proton Mail Bridge needs some manual setup steps.

Add required NixOS Config lines

```
# Proton bridge
services.protonmail-bridge = {
  enable = true;
  path = with pkgs; [ pass gnupg ];
};     
security.pki.certificateFiles = [ ./protonmail-bridge-cert.pem ]; # The Bridge SSL Cert

environment.systemPackages = with pkgs; [
  (...)
  gnupg pass # This is for keychain protonmail bridge stuff
];

```

The pass backend for some reason fails with headless proton-bridge and gnome keyring so create a `pass` backend for it

```
gpg --batch --passphrase '' --quick-gen-key 'protonmail-bridge' default default never
pass init protonmail-bridge
```

It will create the new backend on next run

```
systemctl --user restart protonmail-bridge.service
pass ls # expect a docker-credential-helpers entry
```

Login and setup

```
systemctl --user stop protonmail-bridge.service
protonmail-bridge --cli
>>> login # Proton address + password + 2FA (older builds: "add") 
>>> info # note the ports, security, username, and Bridge password 
>>> exit
systemctl --user start protonmail-bridge.service
```

Create the PEM file so SSL/TLS works with the proton bridge cert locally

```
# Make sure youre somewhere writable, like cd ~

nix-shell -p openssl

openssl s_client -connect 127.0.0.1:1143 -starttls imap </dev/null 2>/dev/null \
  | openssl x509 -outform PEM > protonmail-bridge-cert.pem

openssl x509 -in protonmail-bridge-cert.pem -noout -subject -issuer -ext subjectAltName

sudo mv protonmail-bridge-cert.pem /etc/nixos/
```

Then nixos rebuild switch

Finally, add it to Gnome Accounts (or other) and set the local ip / username / password (not proton user password) and manually set ports if required (proton bridge doesnt use the default smtp ports)
