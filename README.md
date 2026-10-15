[![bluebuild build badge](https://github.com/butrelinux/butrelinux/actions/workflows/build.yml/badge.svg)](https://github.com/butrelinux/butrelinux/actions/workflows/build.yml) [![Build Butrelinux ISO](https://github.com/butrelinux/butrelinux/actions/workflows/build-iso.yml/badge.svg)](https://github.com/butrelinux/butrelinux/actions/workflows/build-iso.yml) [![smoke tests](https://github.com/butrelinux/butrelinux/actions/workflows/image-tests.yml/badge.svg)](https://github.com/butrelinux/butrelinux/actions/workflows/image-tests.yml)  
[![works on my machine badge](https://cdn.jsdelivr.net/gh/nikku/works-on-my-machine@v0.4.0/badge.svg)](https://github.com/nikku/works-on-my-machine) [![Download butrelinux](https://img.shields.io/sourceforge/dt/butrelinux.svg)](https://butrelinux.sourceforge.io/)
# butrelinux
Centos Stream 10 bootc with KDE plasma and many kernel choices

## installation  
ISO downloads available here:  
[![Download butrelinux](https://a.fsdn.com/con/app/sf-download-button)](https://butrelinux.sourceforge.io/)  
the ISO is the main installation path, rebase instructions are provided for convenience for existing el10 bootc users (bluefin-lts, centos-bootc, heliumos, etc.)  

### rebase instructions

if you use the rebase instructions you must rebase from a centos stream derived image such as bluefin-lts, not any fedora version.  this image is based on centos stream 10, not fedora, and cross-rebasing will break things.  

> [!WARNING]  
> [This is an experimental feature](https://www.fedoraproject.org/wiki/Changes/OstreeNativeContainerStable), try at your own discretion.

to rebase an existing EL10 based installation to the latest build:

```bash
# switch to the signed image and reboot:
sudo bootc switch --enforce-container-sigpolicy ghcr.io/butrelinux/<variant>:latest --apply
```
### variants

| variants                                    	| description                                                                                                                    	|
|---------------------------------------------	|--------------------------------------------------------------------------------------------------------------------------------	|
| ghcr.io/butrelinux/lts:latest               	| bone stock centos stream 10 kernel 6.12, with no additional modules loaded.  <br>nvidia support is not provided on this kernel 	|
| ghcr.io/butrelinux/lto:latest               	| tracks link time optimized kernels via bieszczaders/kernel-cachyos-lto                                                         	|
| ghcr.io/butrelinux/lto-nvidia:latest        	| same as above, with nvidia support                                                                                             	|
| ghcr.io/butrelinux/ml:latest                	| tracks elrepo kernel-ml.  if you want fast updates, this is for you                                                            	|
| ghcr.io/butrelinux/ml-nvidia:latest         	| same as above, plus nvidia.  who'd've thought                                                                                  	|
| ghcr.io/butrelinux/hyperscale:latest        	| this tracks the hyperscale SIG kernel.  <br>if you don't know whether you need this, you don't                                 	|
| ghcr.io/butrelinux/hyperscale-nvidia:latest 	| same as above, plus nvidia.  wild how that works                                                                               	|

### verification

these images are signed with sigstore's cosign. you can verify the signature by downloading the cosign.pub file from this repo and running the following command:  
```
cosign verify --key cosign.pub ghcr.io/butrelinux/lts:latest
```
if you ever hit ASN.1 invalid signature failure during an upgrade it's because I rotated out the keys.  sorry.  it was probably dependabot's fault.  you can fetch the new keys with the following command
```
sudo curl -Lo /etc/pki/containers/butrelinux.pub https://raw.githubusercontent.com/butrelinux/butrelinux/refs/heads/main/cosign.pub
```
this shouldn't ever be an issue, but it's worth documenting.

## migration

we're still migrating from butrejp/butrelinux.  pretty close to done though.  existing users can freely rebase to any variant (some old features aren't in place yet, some are being dropped.  if you need brew or soar then stay on the old images, they'll keep building anyway.  the new images get nix instead)  
new users will be able to get an ISO from either this repository's releases or sourceforge, sometime in the next few days/weeks. 

update: hours, apparently.  I put them out a little while ago.  have at it
