# Sözlük / Glossary

Bu projenin teknoloji yığınındaki ve GitHub panosundaki her terimin ne anlama geldiği, İngilizce ve Türkçe. Kavramlar bu depoda nasıl kullanıldıklarıyla birlikte açıklanmıştır.

What every term in this project's tech stack and GitHub board actually means, in English and Turkish, explained through how it is used in this repository.

- **307 terim / terms**
- **71 pano kartı / board items**

## İçindekiler / Contents

- [Temel kavramlar / Core concepts](#core) — 21
- [Terraform & altyapı kodu / Terraform & infrastructure as code](#iac) — 23
- [Bulut & depolama / Cloud & storage](#cloud) — 12
- [Kubernetes & K3s / Kubernetes & K3s](#k8s) — 33
- [GitOps & CI/CD / GitOps & CI/CD](#gitops) — 24
- [Güvenlik & kimlik / Security & identity](#sec) — 32
- [Ağ & edge / Network & edge](#net) — 16
- [Veri & veritabanı / Data & database](#data) — 23
- [Uygulama (Java / Spring) / Application (Java / Spring)](#app) — 30
- [Gözlemlenebilirlik / Observability](#obs) — 19
- [Test & kalite / Testing & quality](#test) — 22
- [Süreç, pano & Git / Process, board & Git](#proc) — 28
- [Bu projeye özel / Specific to this project](#proj) — 24
- [Pano kartları / Board items](#pano) — 71


<a id="core"></a>

## Temel kavramlar / Core concepts

### Blast radius
**TR:** Etki alanı / patlama yarıçapı

How much breaks when one thing breaks. A small blast radius is a design goal, not luck.

Bir şey bozulduğunda kaç şeyin bozulduğu. Küçük etki alanı şans değil, tasarım hedefidir.

> **In XenOpsBase:** Splitting Terraform into cluster / storage / edge roots keeps a destroy in one from touching the others.  
> **XenOpsBase'de:** Terraform'u cluster / storage / edge diye ayırmak, birinde yapılan destroy'un diğerlerine dokunmamasını sağlar.

### Bootstrap
**TR:** Önyükleme / ilk kurulum

The chicken-and-egg first step: creating the thing the automation needs before the automation itself can run.

Tavuk-yumurta problemi olan ilk adım: otomasyon çalışabilsin diye, otomasyondan önce yaratılması gereken şey.

> **In XenOpsBase:** make bootstrap-state creates the bucket Terraform will keep its state in — it has to run before Terraform exists.  
> **XenOpsBase'de:** make bootstrap-state, Terraform'un state'ini koyacağı bucket'ı yaratır — Terraform var olmadan önce çalışmak zorundadır.

### Cattle, not pets
**TR:** Sürü hayvanı, evcil hayvan değil

A server you can kill and replace without ceremony is cattle. A server you nurse back to health because it is unique and irreplaceable is a pet. Pets are a liability.

Öldürüp yerine yenisini koyabildiğin sunucu sürü hayvanıdır. Eşsiz olduğu için tedavi etmeye çalıştığın sunucu evcil hayvandır. Evcil hayvanlar risktir.

> **In XenOpsBase:** ADR-0002. The whole cluster is cattle: nothing that matters is allowed to live inside it.  
> **XenOpsBase'de:** ADR-0002. Kümenin tamamı sürü hayvanıdır: içinde önemli hiçbir şeyin yaşamasına izin verilmez.

### Control plane
**TR:** Kontrol düzlemi

The brain of a system: the part that holds the desired state and tells the workers what to run. Contrast with the data plane, which does the actual work.

Sistemin beyni: istenen durumu tutan ve işçilere ne çalıştıracaklarını söyleyen kısım. Karşıtı, asıl işi yapan veri düzlemidir (data plane).

> **In XenOpsBase:** In Kubernetes the control plane is the API server plus etcd, running on the control-plane nodes.  
> **XenOpsBase'de:** Kubernetes'te kontrol düzlemi, control-plane node'larında koşan API server ve etcd'dir.

### Declarative
**TR:** Bildirimsel

You write down the end state you want; the tool works out the steps to get there. The opposite is imperative, where you write the steps yourself.

İstediğin son durumu yazarsın; oraya nasıl gidileceğini araç kendisi bulur. Zıttı emir kipidir (imperative): adımları sen yazarsın.

> **In XenOpsBase:** Terraform, Kubernetes manifests and Argo CD are all declarative. A shell script is imperative.  
> **XenOpsBase'de:** Terraform, Kubernetes manifest'leri ve Argo CD bildirimseldir. Bir shell script'i emir kipidir.

### Deployable
**TR:** Dağıtılabilir birim

One unit you can build, ship and run on its own — here, one container image per service.

Tek başına derlenip, gönderilip, çalıştırılabilen birim — burada servis başına bir konteyner imajı.

### Drift
**TR:** Sapma

When reality quietly stops matching what the code says — usually because a human changed something by hand.

Gerçek durumun, kodun söylediğinden sessizce ayrılması — genelde birisi elle bir şey değiştirdiği için.

> **In XenOpsBase:** Argo CD marks drifted apps OutOfSync; terraform plan shows drift as changes you did not write.  
> **XenOpsBase'de:** Argo CD sapmış uygulamaları OutOfSync gösterir; terraform plan sapmayı senin yazmadığın değişiklikler olarak listeler.

### Durable state
**TR:** Kalıcı durum

The data that must survive a full teardown: uploaded documents, database backups, Terraform state, git history, container images.

Her şey silinse bile hayatta kalması gereken veri: yüklenen dokümanlar, veritabanı yedekleri, Terraform state, git geçmişi, konteyner imajları.

> **In XenOpsBase:** The two-column table in the README is the durable-state boundary. The left column survives terraform destroy; the right column does not.  
> **XenOpsBase'de:** README'deki iki sütunlu tablo kalıcı durum sınırıdır. Sol sütun terraform destroy'dan sağ çıkar; sağ sütun çıkmaz.

### Environment (dev / staging / prod)
**TR:** Ortam (dev / staging / prod)

Separate, isolated copies of the whole system: dev to break things, staging to rehearse, prod for real users.

Sistemin ayrı ve izole kopyaları: dev kırmak için, staging prova için, prod gerçek kullanıcılar için.

> **In XenOpsBase:** Selected with ENV=dev|staging|prod on make targets; each has its own tfvars, its own buckets and its own state.  
> **XenOpsBase'de:** make komutlarında ENV=dev|staging|prod ile seçilir; her birinin kendi tfvars'ı, kendi bucket'ları ve kendi state'i var.

### Ephemeral
**TR:** Geçici / uçucu

Built to be thrown away and rebuilt. Nothing valuable is stored on it.

Atılıp yeniden kurulmak üzere yapılmış. Üzerinde değerli hiçbir şey saklanmaz.

> **In XenOpsBase:** infra/terraform/cluster is the ephemeral root module — its header literally says so.  
> **XenOpsBase'de:** infra/terraform/cluster geçici kök modüldür — dosyanın başında birebir böyle yazıyor.

### Fork
**TR:** Çatallama / kopya alma

Taking a copy of a repository to grow it in your own direction.

Bir depoyu kendi yönünde geliştirmek üzere kopyalamak.

> **In XenOpsBase:** The stemcell exists to be forked once per new project.  
> **XenOpsBase'de:** Stemcell zaten her yeni proje için bir kez fork'lanmak üzere var.

### Idempotent
**TR:** İdempotent (tekrar-güvenli)

An operation you can run ten times and still end up with exactly the result of running it once.

On kere çalıştırsan da sonucu bir kere çalıştırmışsın gibi kalan işlem.

> **In XenOpsBase:** make bootstrap-state is idempotent: it creates the state bucket if missing and does nothing if it already exists.  
> **XenOpsBase'de:** make bootstrap-state idempotent'tir: bucket yoksa oluşturur, varsa hiçbir şey yapmaz.

### Infrastructure as Code (IaC)
**TR:** Kod olarak altyapı

Servers, networks, databases and DNS described in text files kept in git, and created by running a tool — never by clicking in a web console.

Sunucu, ağ, veritabanı ve DNS ayarlarının git'te duran metin dosyalarında tarif edilmesi ve bir araç çalıştırılarak oluşturulması — asla web panelinden tıklayarak değil.

> **In XenOpsBase:** Everything under infra/terraform. CONTRIBUTING calls this the rule that matters most: if you cannot express a change as code in the repo, that is the bug.  
> **XenOpsBase'de:** infra/terraform altındaki her şey. CONTRIBUTING bunu 'en önemli kural' diye anıyor: bir değişikliği repoda kod olarak ifade edemiyorsan, asıl hata odur.

### Monolith vs microservices
**TR:** Monolit vs mikroservis

A monolith is one deployable containing everything. Microservices split the system into many independently deployable pieces — more flexibility, much more operational cost.

Monolit her şeyi içeren tek bir dağıtılabilir uygulamadır. Mikroservis mimarisi sistemi bağımsız dağıtılabilen çok parçaya böler — daha esnek ama işletme maliyeti çok daha yüksek.

> **In XenOpsBase:** ADR-0001 picks the middle: microservice seams, but only two deployables (gateway + core).  
> **XenOpsBase'de:** ADR-0001 ortayı seçiyor: mikroservis dikişleri var ama sadece iki dağıtılabilir parça (gateway + core).

### Off-the-shelf
**TR:** Hazır çözüm

Using an existing, maintained component instead of writing your own version of it.

Kendi versiyonunu yazmak yerine hazır ve bakımı yapılan bir bileşeni kullanmak.

> **In XenOpsBase:** Stated policy of this repo: auth, logging, orchestration, scaling and document storage are all off-the-shelf.  
> **XenOpsBase'de:** Bu deponun açık politikası: kimlik, loglama, orkestrasyon, ölçekleme ve doküman saklama hep hazır bileşenlerle.

### Orchestration
**TR:** Orkestrasyon

Deciding which container runs on which machine, restarting it when it dies, and moving it when a machine disappears.

Hangi konteynerin hangi makinede koşacağına karar vermek, öldüğünde yeniden başlatmak, makine kaybolunca taşımak.

> **In XenOpsBase:** K3s does this here.  
> **XenOpsBase'de:** Burada bunu K3s yapıyor.

### Provisioning
**TR:** Hazırlama / tedarik

Creating and configuring resources from nothing — servers, disks, DNS records — so they are ready to use.

Kaynakları sıfırdan yaratıp kullanılabilir hale getirmek — sunucular, diskler, DNS kayıtları.

### Reconciliation loop
**TR:** Uzlaştırma döngüsü

A controller that never stops comparing the desired state (what git says) with the real state (what the cluster is doing) and quietly fixes the difference.

İstenen durumu (git'te yazan) gerçek durumla (kümede olan) sürekli karşılaştırıp aradaki farkı sessizce düzelten denetleyici.

> **In XenOpsBase:** This is how Argo CD, cert-manager, CloudNativePG and every Kubernetes operator work.  
> **XenOpsBase'de:** Argo CD, cert-manager, CloudNativePG ve bütün Kubernetes operatörleri böyle çalışır.

### Seam
**TR:** Dikiş (ayrım noktası)

A deliberate boundary in the code where you could later cut a piece out into its own service without rewriting everything.

Kodda bilinçli bırakılmış sınır; ileride oradan bir parçayı kesip ayrı bir servise çıkarmak her şeyi yeniden yazmayı gerektirmez.

> **In XenOpsBase:** T-3.10 is about building these seams in early: audit, soft delete, tenancy, outbox.  
> **XenOpsBase'de:** T-3.10 tam olarak bu dikişleri erkenden bırakmakla ilgili: audit, soft delete, tenancy, outbox.

### Single source of truth
**TR:** Tek doğruluk kaynağı

Exactly one place that defines what is true. Everything else is derived from it, and disagreements are resolved in its favour.

Neyin doğru olduğunu tanımlayan tek bir yer. Diğer her şey ondan türetilir, anlaşmazlıkta o haklıdır.

> **In XenOpsBase:** Here it is the git repository.  
> **XenOpsBase'de:** Burada bu yer git deposudur.

### Vendor lock-in
**TR:** Sağlayıcıya bağımlılık

Depending on one provider so deeply that leaving becomes expensive or impossible.

Bir sağlayıcıya öyle derin bağlanmak ki ayrılmak pahalı ya da imkânsız hale gelir.

> **In XenOpsBase:** Using only the S3 API for object storage is a deliberate hedge against it.  
> **XenOpsBase'de:** Doküman saklamada sadece S3 API kullanmak buna karşı bilinçli bir sigortadır.


<a id="iac"></a>

## Terraform & altyapı kodu / Terraform & infrastructure as code

### Backend
**TR:** Backend

Where Terraform stores its state. An S3 backend means the state file lives in a bucket instead of on your laptop.

Terraform'un state'i sakladığı yer. S3 backend, state dosyasının senin bilgisayarında değil bir bucket'ta durması demek.

### Checkov
**TR:** Checkov

A security scanner for IaC. Flags things like public buckets, unencrypted volumes and wide-open firewall rules before they are applied.

Altyapı kodu için güvenlik tarayıcısı. Herkese açık bucket, şifrelenmemiş disk, sonuna kadar açık firewall kuralı gibi şeyleri uygulanmadan önce işaretler.

> **In XenOpsBase:** .checkov.yaml records which checks are skipped and why — read it before adding a new skip.  
> **XenOpsBase'de:** .checkov.yaml hangi kontrollerin atlandığını ve nedenini kaydeder — yeni bir atlama eklemeden önce oku.

### Data source
**TR:** Data source (veri kaynağı)

A read-only lookup of something Terraform did not create, so you can reference it.

Terraform'un yaratmadığı bir şeyi sadece okumak için yapılan sorgu; böylece ona referans verebilirsin.

### HCL
**TR:** HCL

HashiCorp Configuration Language — the syntax Terraform files are written in. Blocks, arguments, expressions.

HashiCorp Configuration Language — Terraform dosyalarının yazıldığı sözdizimi. Bloklar, argümanlar, ifadeler.

### kube-hetzner
**TR:** kube-hetzner

A community Terraform module that builds a production-shaped K3s cluster on Hetzner: nodes, networking, CCM, CSI, autoscaler.

Hetzner üzerinde üretim kalitesinde K3s kümesi kuran topluluk Terraform modülü: node'lar, ağ, CCM, CSI, autoscaler.

> **In XenOpsBase:** The single biggest dependency in infra/terraform/cluster.  
> **XenOpsBase'de:** infra/terraform/cluster'daki en büyük tek bağımlılık.

### Lock file (.terraform.lock.hcl)
**TR:** Kilit dosyası (.terraform.lock.hcl)

Pins the exact provider versions and their checksums, so every machine and CI run uses identical plugins.

Provider'ların tam sürümlerini ve sağlama toplamlarını sabitler; böylece her makine ve her CI çalışması aynı eklentileri kullanır.

### Makefile / make target
**TR:** Makefile / make hedefi

A named shortcut for a command sequence. make cluster-apply beats remembering nine terraform flags.

Bir komut dizisine verilen kısa ad. make cluster-apply, dokuz tane terraform bayrağını ezberlemekten iyidir.

> **In XenOpsBase:** make help lists every target in this repo.  
> **XenOpsBase'de:** make help bu repodaki tüm hedefleri listeler.

### Module
**TR:** Modül

A reusable folder of Terraform code you call with inputs and get outputs back — like a function.

Girdi verip çıktı aldığın, yeniden kullanılabilir Terraform kodu klasörü — fonksiyon gibi.

> **In XenOpsBase:** kube-hetzner is a third-party module; it is what actually builds the K3s cluster.  
> **XenOpsBase'de:** kube-hetzner üçüncü parti bir modül; K3s kümesini asıl kuran o.

### Packer
**TR:** Packer

Builds a machine image once, so every node boots from an identical, pre-baked disk instead of installing packages at boot.

Makine imajını bir kez üretir; böylece her node açılışta paket kurmak yerine aynı, önceden hazırlanmış diskten başlar.

> **In XenOpsBase:** make snapshot builds the openSUSE MicroOS snapshot kube-hetzner provisions nodes from.  
> **XenOpsBase'de:** make snapshot, kube-hetzner'ın node'ları oluştururken kullandığı openSUSE MicroOS snapshot'ını üretir.

### Partial backend config
**TR:** Kısmi backend yapılandırması

Leaving bucket, region and endpoint out of the code and passing them at init time, so the same code initialises against any environment.

Bucket, bölge ve endpoint bilgisini koda gömmeyip init sırasında vermek; böylece aynı kod her ortama kurulabilir.

> **In XenOpsBase:** terraform init -backend-config=backend.hcl  
> **XenOpsBase'de:** terraform init -backend-config=backend.hcl

### Provider
**TR:** Provider (sağlayıcı eklentisi)

A plugin that teaches Terraform how to talk to one API — hcloud for Hetzner, cloudflare for Cloudflare, aws for S3-compatible storage.

Terraform'a tek bir API ile nasıl konuşacağını öğreten eklenti — Hetzner için hcloud, Cloudflare için cloudflare, S3 uyumlu depolama için aws.

> **In XenOpsBase:** Declared in versions.tf with a version constraint.  
> **XenOpsBase'de:** versions.tf içinde sürüm kısıtıyla birlikte tanımlanır.

### Resource
**TR:** Resource (kaynak)

One thing Terraform creates and owns — a server, a bucket, a DNS record. Written as resource "type" "name" { ... }.

Terraform'un yarattığı ve sahiplendiği tek bir şey — bir sunucu, bir bucket, bir DNS kaydı.

### Root module
**TR:** Kök modül

The directory you actually run terraform in. It has its own state and its own lifecycle.

terraform komutunu içinde çalıştırdığın dizin. Kendi state'i ve kendi yaşam döngüsü vardır.

> **In XenOpsBase:** Three of them here: cluster (ephemeral), storage (durable), edge (Cloudflare).  
> **XenOpsBase'de:** Burada üç tane var: cluster (geçici), storage (kalıcı), edge (Cloudflare).

### Snapshot
**TR:** Snapshot (disk anlık görüntüsü)

A frozen copy of a disk you can create new servers from.

Yeni sunucular yaratmak için kullanabildiğin, dondurulmuş disk kopyası.

> **In XenOpsBase:** T-0.6 argues the OS snapshot belongs in the durable-state table: destroy the cluster and you still need it to rebuild.  
> **XenOpsBase'de:** T-0.6, OS snapshot'ının kalıcı durum tablosuna ait olduğunu savunuyor: kümeyi silsen bile yeniden kurmak için ona ihtiyacın var.

### State locking
**TR:** State kilitleme

A lock that stops two people (or two CI jobs) applying at once and corrupting the state file.

İki kişinin (ya da iki CI işinin) aynı anda apply çalıştırıp state dosyasını bozmasını engelleyen kilit.

> **In XenOpsBase:** use_lockfile = true — implemented with a conditional PutObject in R2. make verify-locking proves it actually refuses.  
> **XenOpsBase'de:** use_lockfile = true — R2'de koşullu PutObject ile yapılıyor. make verify-locking gerçekten reddettiğini kanıtlıyor.

### Terraform
**TR:** Terraform

The tool that reads your .tf files, works out the difference between them and the real cloud, and applies it. Written in HCL.

Senin .tf dosyalarını okuyup gerçek bulut ile aralarındaki farkı hesaplayan ve uygulayan araç. HCL dilinde yazılır.

> **In XenOpsBase:** Everything infrastructural in this repo is built by Terraform, in three separate root modules.  
> **XenOpsBase'de:** Bu repodaki tüm altyapı Terraform ile kuruluyor, üç ayrı kök modülde.

### terraform apply
**TR:** terraform apply

Actually makes the changes the plan described.

Plan'ın anlattığı değişiklikleri gerçekten yapar.

### terraform destroy
**TR:** terraform destroy

Deletes everything in that root module's state. Irreversible for anything not backed up elsewhere.

O kök modülün state'indeki her şeyi siler. Başka yerde yedeği olmayan her şey için geri dönüşü yoktur.

> **In XenOpsBase:** make cluster-destroy is the routine path here, and deliberately cannot reach the storage module.  
> **XenOpsBase'de:** Burada make cluster-destroy rutin yoldur ve bilinçli olarak storage modülüne erişemez.

### terraform fmt
**TR:** terraform fmt

Rewrites .tf files into the canonical formatting so diffs stay about content, not whitespace.

.tf dosyalarını standart biçime sokar; böylece diff'ler boşluk değil içerik hakkında olur.

> **In XenOpsBase:** make fmt, and checked in CI.  
> **XenOpsBase'de:** make fmt, ayrıca CI'da kontrol ediliyor.

### terraform plan
**TR:** terraform plan

A dry run: shows exactly what would be created, changed or destroyed, without doing it.

Kuru çalıştırma: neyin yaratılacağını, değişeceğini veya silineceğini yapmadan gösterir.

> **In XenOpsBase:** Runs automatically on every PR that touches infra (T-1.8). Read the destroy lines first.  
> **XenOpsBase'de:** Altyapıya dokunan her PR'da otomatik çalışır (T-1.8). Önce destroy satırlarını oku.

### Terraform state
**TR:** Terraform state (durum dosyası)

The JSON file mapping the resources in your code to the real IDs in the cloud. Lose it and Terraform no longer knows what it owns.

Kodundaki kaynakları buluttaki gerçek kimliklerle eşleyen JSON dosyası. Kaybedersen Terraform neye sahip olduğunu artık bilmez.

> **In XenOpsBase:** ADR-0005: kept in Cloudflare R2, not Hetzner, because R2 supports the conditional writes needed for locking.  
> **XenOpsBase'de:** ADR-0005: Hetzner'de değil Cloudflare R2'de tutuluyor, çünkü kilitleme için gereken koşullu yazmayı R2 destekliyor.

### tflint
**TR:** tflint

A linter for Terraform: catches invalid instance types, deprecated syntax and unused declarations that terraform validate misses.

Terraform için linter: geçersiz makine tipleri, kullanımdan kalkmış sözdizimi ve terraform validate'in kaçırdığı kullanılmayan tanımları yakalar.

### tfvars
**TR:** tfvars dosyası

A file of variable values for one environment. env/dev.tfvars, env/prod.tfvars.

Tek bir ortama ait değişken değerlerini tutan dosya. env/dev.tfvars, env/prod.tfvars.

> **In XenOpsBase:** *.secrets.tfvars holds the values that must never be committed in plaintext.  
> **XenOpsBase'de:** *.secrets.tfvars, asla düz metin olarak commit'lenmemesi gereken değerleri tutar.


<a id="cloud"></a>

## Bulut & depolama / Cloud & storage

### Bucket
**TR:** Bucket (kova)

A named container inside object storage. Everything in it is addressed by a key, which looks like a path but is just a string.

Nesne depolamanın içindeki adlandırılmış kap. İçindeki her şey, yola benzeyen ama aslında düz metin olan bir anahtarla adreslenir.

### Bucket versioning
**TR:** Bucket versiyonlama

Every overwrite keeps the previous copy instead of destroying it. Turns an accidental delete into an undo.

Her üzerine yazma, eskisini silmek yerine saklar. Kazara silmeyi geri alınabilir hale getirir.

> **In XenOpsBase:** On for the Terraform state bucket and the durable buckets (T-1.2).  
> **XenOpsBase'de:** Terraform state bucket'ında ve kalıcı bucket'larda açık (T-1.2).

### cloud-init
**TR:** cloud-init

The standard way a fresh virtual machine configures itself on first boot from a text file handed to it by the provider.

Yeni bir sanal makinenin ilk açılışta, sağlayıcının verdiği metin dosyasına göre kendini yapılandırmasının standart yolu.

### Cloudflare R2
**TR:** Cloudflare R2

Cloudflare's S3-compatible object storage. Notable here because it supports conditional writes, which is what makes Terraform state locking possible.

Cloudflare'in S3 uyumlu nesne depolaması. Burada önemli olma sebebi koşullu yazmayı desteklemesi; Terraform state kilitlemesini mümkün kılan şey bu.

> **In XenOpsBase:** ADR-0005.  
> **XenOpsBase'de:** ADR-0005.

### GHCR
**TR:** GHCR (GitHub Container Registry)

GitHub's container image registry. Where the built images for gateway and core are pushed and pulled from.

GitHub'ın konteyner imaj deposu. Gateway ve core imajlarının gönderildiği ve çekildiği yer.

### Hetzner Cloud
**TR:** Hetzner Cloud

The German cloud provider this project runs on. Cheap virtual servers, an object store and a private network API.

Bu projenin üzerinde koştuğu Alman bulut sağlayıcısı. Ucuz sanal sunucular, bir nesne deposu ve özel ağ API'si.

> **In XenOpsBase:** Driven by the hcloud Terraform provider with a token from HCLOUD_TOKEN.  
> **XenOpsBase'de:** HCLOUD_TOKEN'daki token ile hcloud Terraform provider'ı üzerinden yönetiliyor.

### Lifecycle rule
**TR:** Yaşam döngüsü kuralı

An automatic policy on a bucket: delete objects after N days, expire old versions, clean up incomplete uploads. This is your cost control.

Bucket üzerinde otomatik kural: N gün sonra sil, eski sürümleri sonlandır, yarım kalan yüklemeleri temizle. Maliyet kontrolün budur.

> **In XenOpsBase:** infra/lifecycle/<environment>/*.json, applied by make storage-lifecycle.  
> **XenOpsBase'de:** infra/lifecycle/<environment>/*.json dosyaları, make storage-lifecycle ile uygulanıyor.

### Node
**TR:** Node (düğüm / makine)

One machine in the cluster. Here, one Hetzner virtual server.

Kümedeki tek bir makine. Burada bir Hetzner sanal sunucusu.

### Node pool
**TR:** Node havuzu

A group of identical nodes managed together — same size, same role, scaled as a unit.

Birlikte yönetilen, aynı boyut ve rolde node'lar grubu; tek birim olarak ölçeklenir.

### Object storage
**TR:** Nesne depolama

Storage for whole files addressed by a key, not a filesystem. Cheap, durable, accessed over HTTP.

Dosya sistemi değil, anahtarla adreslenen dosya deposu. Ucuz, dayanıklı, HTTP üzerinden erişilir.

> **In XenOpsBase:** Holds the three things that must never die: documents, Postgres backups, Loki chunks.  
> **XenOpsBase'de:** Asla ölmemesi gereken üç şeyi tutar: dokümanlar, Postgres yedekleri, Loki chunk'ları.

### openSUSE MicroOS
**TR:** openSUSE MicroOS

A minimal, immutable, self-updating operating system built for running containers. The node OS kube-hetzner uses.

Konteyner çalıştırmak için yapılmış minimal, değiştirilemez, kendini güncelleyen işletim sistemi. kube-hetzner'ın node OS'u.

### S3-compatible
**TR:** S3 uyumlu

Speaks the same API as Amazon S3 without being AWS. Most tools work unchanged; some AWS-specific behaviours have to be switched off.

AWS olmadan Amazon S3 ile aynı API'yi konuşur. Çoğu araç değişmeden çalışır; bazı AWS'e özel davranışları kapatmak gerekir.

> **In XenOpsBase:** That is what all those skip_* flags in the S3 backend block are for.  
> **XenOpsBase'de:** S3 backend bloğundaki o skip_* bayraklarının sebebi tam olarak bu.


<a id="k8s"></a>

## Kubernetes & K3s / Kubernetes & K3s

### API server
**TR:** API server

The single front door to the cluster. Every kubectl command, every controller, every operator talks only to this.

Kümeye açılan tek kapı. Her kubectl komutu, her controller, her operatör yalnızca buraya konuşur.

### CCM
**TR:** CCM (Cloud Controller Manager)

The bridge between Kubernetes and the cloud provider's API: registers nodes, creates load balancers, attaches volumes.

Kubernetes ile bulut sağlayıcının API'si arasındaki köprü: node'ları kaydeder, load balancer yaratır, diskleri bağlar.

> **In XenOpsBase:** T-1.10 was exactly this breaking when node traffic moved onto Tailscale.  
> **XenOpsBase'de:** T-1.10 tam da bunun, node trafiği Tailscale'e taşınınca bozulmasıydı.

### Cluster
**TR:** Küme (cluster)

A set of machines acting as one Kubernetes system.

Tek bir Kubernetes sistemi gibi davranan makineler bütünü.

### cluster-autoscaler
**TR:** cluster-autoscaler

Adds and removes whole nodes when pods cannot be scheduled or nodes sit empty.

Pod'lar yerleştirilemediğinde ya da node'lar boş kaldığında node ekleyip çıkarır.

### CNI
**TR:** CNI (Container Network Interface)

The plugin that gives every pod an IP and makes pod-to-pod traffic work across nodes.

Her pod'a IP veren ve node'lar arası pod trafiğini çalıştıran eklenti.

### ConfigMap
**TR:** ConfigMap

Same shape as a Secret but for non-sensitive configuration.

Secret ile aynı yapıda ama hassas olmayan yapılandırma için.

### CRD / Custom Resource
**TR:** CRD / Özel Kaynak

A way to teach the Kubernetes API a new object type. After a CRD is installed, kind: Cluster or kind: Keycloak becomes as native as kind: Pod.

Kubernetes API'sine yeni bir nesne tipi öğretme yolu. CRD kurulduktan sonra kind: Cluster veya kind: Keycloak, kind: Pod kadar yerleşik olur.

### CSI
**TR:** CSI (Container Storage Interface)

The standard plugin interface that lets Kubernetes create real cloud disks when a pod asks for one.

Pod disk istediğinde Kubernetes'in gerçek bulut diski yaratmasını sağlayan standart eklenti arayüzü.

### DaemonSet
**TR:** DaemonSet

Runs exactly one copy of a pod on every node. Log and metric agents work this way.

Her node'da tam olarak bir kopya pod çalıştırır. Log ve metrik ajanları böyle çalışır.

### Deployment
**TR:** Deployment

Says keep N identical stateless pods running, and roll them one at a time when the image changes.

N adet aynı durumsuz pod'u ayakta tut, imaj değişince teker teker yenile demektir.

### etcd
**TR:** etcd

The key-value database holding the entire cluster state. If it is gone, the cluster's memory is gone.

Tüm küme durumunu tutan anahtar-değer veritabanı. O giderse kümenin hafızası gider.

### Helm
**TR:** Helm

A package manager for Kubernetes. A chart is a parameterised bundle of manifests; values.yaml is your configuration of it.

Kubernetes için paket yöneticisi. Chart, parametrelenmiş manifest paketidir; values.yaml da senin ayarlarındır.

### HPA
**TR:** HPA (Yatay Pod Ölçekleyici)

Adds and removes pod replicas automatically based on CPU, memory or a custom metric.

CPU, bellek ya da özel bir metriğe göre pod kopyalarını otomatik artırıp azaltır.

### Ingress
**TR:** Ingress

The rule that says which hostname and path from outside maps to which internal service.

Dışarıdan gelen hangi alan adı ve yolun hangi iç servise gideceğini söyleyen kural.

### ingress-nginx
**TR:** ingress-nginx

The controller that actually reads Ingress objects and turns them into a running nginx reverse proxy.

Ingress nesnelerini gerçekten okuyup çalışan bir nginx ters vekiline dönüştüren denetleyici.

### K3s
**TR:** K3s

A lightweight, single-binary Kubernetes distribution. Same API, far less memory — which matters on small Hetzner nodes.

Hafif, tek dosyadan oluşan Kubernetes dağıtımı. Aynı API, çok daha az bellek — küçük Hetzner node'larında bu önemli.

### kubeconfig
**TR:** kubeconfig

The file holding the cluster address plus your credentials for it. Whoever has it can act as you.

Küme adresini ve oraya ait kimlik bilgilerini tutan dosya. Kimde varsa senin yerine hareket edebilir.

> **In XenOpsBase:** make kubeconfig writes it out of Terraform state; it is gitignored.  
> **XenOpsBase'de:** make kubeconfig onu Terraform state'inden çıkarır; gitignore'da.

### kubectl
**TR:** kubectl

The command-line client for the API server.

API server için komut satırı istemcisi.

> **In XenOpsBase:** Reading with kubectl is fine here. Creating with kubectl is forbidden — that is state no rebuild can reproduce.  
> **XenOpsBase'de:** Burada kubectl ile okumak serbest. kubectl ile yaratmak yasak — bu, hiçbir yeniden kurulumun üretemeyeceği bir durumdur.

### Kubernetes (K8s)
**TR:** Kubernetes (K8s)

The system that runs containers across a fleet of machines: schedules them, restarts them, networks them, and keeps the declared number alive.

Konteynerleri bir makine filosunda çalıştıran sistem: zamanlar, yeniden başlatır, ağ verir ve beyan edilen sayıda ayakta tutar.

### Kustomize
**TR:** Kustomize

Layers patches over a base set of plain manifests instead of templating them. Built into kubectl.

Manifest'leri şablonlamak yerine, temel bir set üzerine yamalar bindirir. kubectl'in içinde gelir.

> **In XenOpsBase:** platform/envs/dev/kustomization.yaml is the entry point Argo CD renders.  
> **XenOpsBase'de:** platform/envs/dev/kustomization.yaml, Argo CD'nin işlediği giriş noktasıdır.

### Manifest
**TR:** Manifest

A YAML file describing one Kubernetes object you want to exist.

Var olmasını istediğin tek bir Kubernetes nesnesini tarif eden YAML dosyası.

### Namespace
**TR:** Namespace (ad alanı)

A folder inside the cluster that groups objects and gives them a scope for names, quotas and access rules.

Küme içinde nesneleri gruplayan, isim/kota/erişim kapsamı veren klasör.

### OOMKilled
**TR:** OOMKilled (bellek yetmedi, öldürüldü)

The kernel killed a container for exceeding its memory limit. Shows up as a restart loop with no useful application log.

Çekirdek, bellek limitini aşan konteyneri öldürdü. Uygulama logunda hiçbir ipucu olmadan sürekli yeniden başlama olarak görünür.

> **In XenOpsBase:** T-1.12: the dev cluster ran out of memory headroom and the Argo repo-server kept dying.  
> **XenOpsBase'de:** T-1.12: dev kümesinde bellek payı bitti ve Argo repo-server sürekli öldü.

### Operator
**TR:** Operatör

A controller that encodes an expert's operational knowledge for one piece of software: install, upgrade, back up, fail over, all as reconciliation.

Tek bir yazılım için uzman işletme bilgisini koda döken denetleyici: kurulum, yükseltme, yedekleme, devretme — hepsi uzlaştırma döngüsüyle.

> **In XenOpsBase:** CloudNativePG and the Keycloak operator are the two that matter here.  
> **XenOpsBase'de:** Burada önemli olan ikisi: CloudNativePG ve Keycloak operatörü.

### PersistentVolumeClaim (PVC)
**TR:** PersistentVolumeClaim (PVC)

A pod asking for a disk of a given size. The claim is bound to a real volume created by the storage driver.

Bir pod'un belirli boyutta disk istemesi. Bu istek, depolama sürücüsünün yarattığı gerçek bir diske bağlanır.

> **In XenOpsBase:** Cluster-scoped and therefore disposable — but the underlying Hetzner volume can be orphaned and keep billing (T-1.11).  
> **XenOpsBase'de:** Küme kapsamlı ve dolayısıyla atılabilir — ama altındaki Hetzner diski sahipsiz kalıp faturalanmaya devam edebilir (T-1.11).

### Pod
**TR:** Pod

The smallest thing Kubernetes runs: one or more containers sharing a network address and lifetime. Pods are disposable by design.

Kubernetes'in çalıştırdığı en küçük şey: aynı ağ adresini ve ömrü paylaşan bir veya birkaç konteyner. Pod'lar tasarım gereği atılabilirdir.

### Probe (readiness / liveness)
**TR:** Probe (hazır / canlı kontrolü)

Readiness decides whether a pod receives traffic; liveness decides whether it gets restarted. A pod can be alive and still not ready.

Readiness pod'a trafik gidip gitmeyeceğine, liveness yeniden başlatılıp başlatılmayacağına karar verir. Bir pod canlı ama hazır olmayabilir.

### Requests and limits
**TR:** Requests ve limits

Request is the CPU and memory reserved for a pod (used for scheduling). Limit is the ceiling before it is throttled or killed.

Request, pod için ayrılan CPU ve bellek (zamanlama buna göre yapılır). Limit ise kısılmadan veya öldürülmeden önceki tavandır.

### Secret
**TR:** Secret (gizli değer nesnesi)

A Kubernetes object holding sensitive values. Base64 is encoding, not encryption — a raw Secret in git is plaintext.

Hassas değerleri tutan Kubernetes nesnesi. Base64 şifreleme değil kodlamadır — git'teki ham bir Secret düz metindir.

> **In XenOpsBase:** Which is why every Secret in platform/envs/*/secrets/ is SOPS-encrypted.  
> **XenOpsBase'de:** Bu yüzden platform/envs/*/secrets/ altındaki her Secret SOPS ile şifreli.

### Service
**TR:** Service (servis)

A stable internal name and IP in front of a changing set of pods. Pods come and go; the service address does not.

Sürekli değişen pod kümesinin önünde duran sabit iç isim ve IP. Pod'lar gelir gider, servis adresi durur.

### StatefulSet
**TR:** StatefulSet

Like a Deployment but for pods with identity and their own disk — stable names, ordered startup, a persistent volume each.

Deployment gibi ama kimliği ve kendi diski olan pod'lar için — sabit isimler, sıralı başlatma, her birine kalıcı disk.

### Taint and toleration
**TR:** Taint ve toleration

A taint marks a node as do not schedule here; a toleration is a pod's permission to ignore that mark.

Taint bir node'a buraya yerleştirme damgası vurur; toleration ise bir pod'un bu damgayı yok sayma iznidir.

### Velero
**TR:** Velero

Backs up Kubernetes objects (and optionally volumes) to object storage, so a cluster's resources can be restored elsewhere.

Kubernetes nesnelerini (ve istenirse diskleri) nesne depolamaya yedekler; böylece kaynaklar başka yerde geri yüklenebilir.

> **In XenOpsBase:** T-2.9, deliberately low priority: in a GitOps repo, git is already the backup of every manifest.  
> **XenOpsBase'de:** T-2.9, bilinçli olarak düşük öncelikli: GitOps deposunda git zaten her manifest'in yedeğidir.


<a id="gitops"></a>

## GitOps & CI/CD / GitOps & CI/CD

### App-of-apps
**TR:** App-of-apps (uygulamaların uygulaması)

One root Application whose only job is to create all the other Applications. Terraform installs one thing; that one thing pulls in the entire platform.

Tek görevi diğer tüm Application'ları yaratmak olan tek bir kök Application. Terraform tek bir şey kurar; o tek şey tüm platformu içeri çeker.

> **In XenOpsBase:** infra/terraform/cluster/manifests/20-root-app/  
> **XenOpsBase'de:** infra/terraform/cluster/manifests/20-root-app/

### Application (Argo CD)
**TR:** Application (Argo CD)

A custom resource that says: take this path in this git repo, and make the cluster look like it.

Şu git deposundaki şu yolu al ve kümeyi ona benzet diyen özel kaynak.

### Argo CD
**TR:** Argo CD

The GitOps engine here. Watches the repo, renders the manifests, applies them, and reports whether the cluster matches.

Buradaki GitOps motoru. Depoyu izler, manifest'leri işler, uygular ve kümenin eşleşip eşleşmediğini raporlar.

> **In XenOpsBase:** Bootstrapped by Terraform as a HelmChart plus a root Application (T-2.1).  
> **XenOpsBase'de:** Terraform tarafından bir HelmChart ve bir kök Application olarak kuruluyor (T-2.1).

### CI / CD
**TR:** CI / CD (sürekli entegrasyon / sürekli teslimat)

CI builds and tests every change automatically. CD gets the tested result into an environment automatically.

CI her değişikliği otomatik derler ve test eder. CD test edilmiş sonucu otomatik olarak bir ortama taşır.

### Container image
**TR:** Konteyner imajı

A frozen, layered filesystem plus a start command. Running one gives you a container.

Dondurulmuş, katmanlı bir dosya sistemi ve bir başlatma komutu. Birini çalıştırınca konteyner olur.

### Dependabot / Renovate
**TR:** Dependabot / Renovate

Bots that open pull requests to bump your dependencies, so upgrades arrive continuously instead of as one terrifying annual jump.

Bağımlılıklarını güncellemek için pull request açan botlar; böylece yükseltmeler yılda bir korkunç sıçrama yerine sürekli gelir.

### Flux
**TR:** Flux

The main alternative GitOps engine to Argo CD. Lighter, no built-in UI, more composable.

Argo CD'ye ana alternatif GitOps motoru. Daha hafif, dahili arayüzü yok, daha modüler.

> **In XenOpsBase:** Considered and rejected in ADR-0004.  
> **XenOpsBase'de:** ADR-0004'te değerlendirildi ve seçilmedi.

### GitHub Actions
**TR:** GitHub Actions

GitHub's CI system. A workflow is a YAML file in .github/workflows/ made of jobs, each made of steps, run on a runner.

GitHub'ın CI sistemi. Workflow, .github/workflows/ içinde bir YAML dosyasıdır; job'lardan, onlar da runner üzerinde koşan step'lerden oluşur.

> **In XenOpsBase:** Three here: pr-conventions, secrets, terraform.  
> **XenOpsBase'de:** Burada üç tane var: pr-conventions, secrets, terraform.

### GitOps
**TR:** GitOps

Git is the only way to change the cluster. You commit; an agent inside the cluster notices and applies it. Nobody deploys by hand.

Kümeyi değiştirmenin tek yolu git'tir. Sen commit'lersin; kümedeki bir ajan bunu fark edip uygular. Kimse elle dağıtım yapmaz.

> **In XenOpsBase:** ADR-0004. Argo CD is the agent.  
> **XenOpsBase'de:** ADR-0004. Ajan Argo CD.

### Jib
**TR:** Jib

Builds a container image straight from Maven with no Dockerfile and no Docker daemon, and layers it so only changed classes are re-pushed.

Dockerfile ve Docker daemon olmadan doğrudan Maven'dan konteyner imajı üretir; katmanlar sayesinde yalnızca değişen sınıflar yeniden gönderilir.

> **In XenOpsBase:** T-6.1.  
> **XenOpsBase'de:** T-6.1.

### Maven
**TR:** Maven

The Java build tool. pom.xml declares dependencies and plugins; mvnw is the wrapper that pins the Maven version itself.

Java derleme aracı. pom.xml bağımlılıkları ve eklentileri tanımlar; mvnw ise Maven sürümünü sabitleyen sarmalayıcıdır.

### OutOfSync
**TR:** OutOfSync (eşleşmiyor)

Argo CD's word for drift: the live cluster does not match the repo.

Argo CD'nin sapma için kullandığı sözcük: canlı küme depoyla uyuşmuyor.

### Promotion
**TR:** Promotion (ortam yükseltme)

Moving the exact same tested artifact from dev to staging to prod by changing a reference in git — not by rebuilding it.

Aynı test edilmiş çıktıyı git'te bir referans değiştirerek dev'den staging'e, oradan prod'a taşımak — yeniden derleyerek değil.

> **In XenOpsBase:** T-6.3.  
> **XenOpsBase'de:** T-6.3.

### Prune
**TR:** Prune (budama)

Deleting cluster objects whose manifests were removed from git. Without it, deleted files leave orphans behind.

Manifest'i git'ten silinmiş küme nesnelerini silmek. Bu olmazsa silinen dosyalar arkada yetim nesneler bırakır.

### repo-server
**TR:** repo-server

The Argo CD component that clones your git repo and renders Helm and Kustomize into plain manifests. Memory-hungry.

Git deponu klonlayıp Helm ve Kustomize'ı düz manifest'e çeviren Argo CD bileşeni. Belleğe aç.

> **In XenOpsBase:** The component that was crash-looping in T-1.12.  
> **XenOpsBase'de:** T-1.12'de sürekli çöküp duran bileşen buydu.

### Required check
**TR:** Zorunlu kontrol

A CI job that must pass green before a pull request can merge. This is where a convention stops being a suggestion.

Bir pull request birleşmeden önce yeşil geçmesi zorunlu olan CI işi. Bir kuralın tavsiye olmaktan çıktığı yer burasıdır.

### Rollback
**TR:** Rollback (geri alma)

Returning to the previous known-good version fast. In GitOps this is a git revert, which is why the target is under five minutes.

Bilinen son çalışan sürüme hızla dönmek. GitOps'ta bu bir git revert'tür; hedefin beş dakikanın altı olmasının sebebi bu.

> **In XenOpsBase:** T-6.4.  
> **XenOpsBase'de:** T-6.4.

### Runner
**TR:** Runner

The machine a CI job actually executes on.

CI işinin gerçekten üzerinde çalıştığı makine.

### SBOM
**TR:** SBOM (yazılım malzeme listesi)

A machine-readable list of every library inside your image, so a new CVE can be answered with a query instead of a guess.

İmajının içindeki her kütüphanenin makine okur listesi; yeni bir CVE çıktığında tahmin yerine sorguyla cevap verirsin.

### Self-heal
**TR:** Self-heal (kendini onarma)

Argo CD reverting any change made outside git, automatically. This is what makes manual kubectl edits pointless.

Argo CD'nin git dışında yapılan değişikliği otomatik geri alması. Elle yapılan kubectl düzenlemelerini anlamsız kılan şey budur.

### Signing and provenance
**TR:** İmzalama ve köken kanıtı

Cryptographically signing an image (cosign) and attaching a record of how it was built (SLSA provenance), then refusing to deploy anything unsigned.

İmajı kriptografik olarak imzalamak (cosign) ve nasıl üretildiğinin kaydını eklemek (SLSA provenance), sonra imzasız hiçbir şeyi dağıtmamak.

> **In XenOpsBase:** T-6.2.  
> **XenOpsBase'de:** T-6.2.

### Supply chain security
**TR:** Tedarik zinciri güvenliği

Proving the artifact you deploy is the one your CI built from your source, and nothing was swapped in between.

Dağıttığın çıktının, CI'ın senin kaynağından ürettiği şey olduğunu ve arada hiçbir şeyin değiştirilmediğini kanıtlamak.

### Sync
**TR:** Sync (eşitleme)

Argo CD applying what git says to the cluster. Manual sync waits for a click; automated sync happens on its own.

Argo CD'nin git'te yazanı kümeye uygulaması. Manuel sync tıklama bekler; otomatik sync kendiliğinden olur.

### Tag vs digest
**TR:** Tag vs digest

A tag like :latest is a movable label. A digest (sha256:...) names exact bytes and can never change. Deploy by digest if you want reproducibility.

latest gibi bir tag taşınabilir etikettir. Digest (sha256:...) tam olarak o baytları adlandırır ve asla değişmez. Tekrarlanabilirlik istiyorsan digest ile dağıt.


<a id="sec"></a>

## Güvenlik & kimlik / Security & identity

### Access token
**TR:** Access token (erişim jetonu)

The short-lived token sent with each API call to prove the caller is allowed.

Her API çağrısıyla gönderilen, çağıranın yetkili olduğunu kanıtlayan kısa ömürlü token.

### age
**TR:** age

A small modern encryption tool. One keypair per environment; the private key is the single bootstrap secret you must supply by hand.

Küçük ve modern bir şifreleme aracı. Ortam başına bir anahtar çifti; özel anahtar, elle vermek zorunda olduğun tek bootstrap sırrıdır.

### Audience (aud)
**TR:** Audience (aud)

Who the token was meant for. Validating it stops a token issued for service A being replayed against service B.

Token'ın kime yönelik olduğu. Doğrulamak, A servisi için üretilmiş token'ın B servisine karşı kullanılmasını engeller.

> **In XenOpsBase:** AudienceValidator.java in the core service.  
> **XenOpsBase'de:** core servisindeki AudienceValidator.java.

### Authorization code flow
**TR:** Authorization code akışı

The standard browser login dance: redirect to Keycloak, log in, come back with a short code, exchange that code for tokens on the server side.

Standart tarayıcı giriş dansı: Keycloak'a yönlendir, giriş yap, kısa bir kodla dön, o kodu sunucu tarafında token'larla takas et.

### cert-manager
**TR:** cert-manager

The operator that requests, installs and renews TLS certificates inside the cluster automatically.

Küme içinde TLS sertifikalarını otomatik isteyen, kuran ve yenileyen operatör.

### Claim
**TR:** Claim (iddia / alan)

One field inside a token: sub, email, preferred_username, roles. Claims are optional — code that assumes one is always present is a bug.

Token içindeki tek bir alan: sub, email, preferred_username, roles. Claim'ler isteğe bağlıdır — birinin hep var olduğunu varsayan kod hatalıdır.

> **In XenOpsBase:** T-3.12 was exactly that: a NullPointerException when preferred_username was missing.  
> **XenOpsBase'de:** T-3.12 tam olarak buydu: preferred_username yokken NullPointerException.

### Client (OAuth)
**TR:** Client (OAuth istemcisi)

An application registered with the identity server. Public clients (browsers) hold no secret; confidential clients (your gateway) do.

Kimlik sunucusuna kayıtlı uygulama. Public client'lar (tarayıcı) gizli anahtar tutmaz; confidential client'lar (gateway'in) tutar.

### CVE
**TR:** CVE (bilinen güvenlik açığı)

A publicly catalogued vulnerability with an ID. Scanners match your dependency list against the catalogue.

Kimliği olan, herkese açık kayıtlı güvenlik açığı. Tarayıcılar bağımlılık listeni bu katalogla karşılaştırır.

### DNS-01 challenge
**TR:** DNS-01 doğrulaması

Proving domain control by writing a TXT record instead of serving a file over HTTP. Needed when nothing is publicly reachable — which is the case here.

Alan adı sahipliğini, HTTP üzerinden dosya sunmak yerine TXT kaydı yazarak kanıtlamak. Dışarıdan hiçbir şeye erişilemediğinde gerekir — burada durum bu.

> **In XenOpsBase:** T-2.2, using a Cloudflare API token.  
> **XenOpsBase'de:** T-2.2, bir Cloudflare API token'ı ile.

### External Secrets Operator
**TR:** External Secrets Operator

Pulls secrets from an external vault at runtime and materialises them as Kubernetes Secrets, so nothing sensitive is in git at all.

Sırları çalışma anında harici bir kasadan çekip Kubernetes Secret'ı olarak oluşturur; böylece git'te hiçbir hassas veri bulunmaz.

> **In XenOpsBase:** The alternative weighed against SOPS in ADR-0003.  
> **XenOpsBase'de:** ADR-0003'te SOPS'a karşı tartılan alternatif.

### ID token
**TR:** ID token (kimlik jetonu)

The token that describes who logged in. For the application, not for the API.

Kimin giriş yaptığını anlatan token. API için değil, uygulama için.

### Issuer (iss)
**TR:** Issuer (iss)

The URL of the identity server that minted the token. The consumer checks it matches the one it trusts.

Token'ı üreten kimlik sunucusunun adresi. Alan taraf, güvendiği adresle eşleştiğini kontrol eder.

### JWKS
**TR:** JWKS

The public keys the identity server publishes so anyone can verify a token signature without calling it for every request.

Kimlik sunucusunun yayımladığı açık anahtarlar; herkes her istek için ona sormadan token imzasını doğrulayabilir.

### JWT
**TR:** JWT (JSON Web Token)

A signed, self-describing token. Anyone can read it; only the issuer can produce a valid signature. Not encrypted — never put secrets in one.

İmzalı, kendini tanımlayan token. Herkes okuyabilir; geçerli imzayı sadece üreten atabilir. Şifreli değildir — içine sır koyma.

### Keycloak
**TR:** Keycloak

The identity server. It owns users, passwords, logins, sessions and tokens, so your application never has to.

Kimlik sunucusu. Kullanıcıları, parolaları, girişleri, oturumları ve token'ları o yönetir; uygulaman hiç uğraşmaz.

### Least privilege
**TR:** En az yetki ilkesi

Every credential gets the narrowest permission that still works: this bucket, this action, nothing else.

Her kimlik bilgisi işini görecek en dar izni alır: bu bucket, bu eylem, başka hiçbir şey.

> **In XenOpsBase:** infra/terraform/storage/policies.tf.  
> **XenOpsBase'de:** infra/terraform/storage/policies.tf.

### Let's Encrypt / ACME
**TR:** Let's Encrypt / ACME

A free certificate authority and the protocol for proving you control a domain before it issues you a certificate.

Ücretsiz sertifika otoritesi ve sertifika vermeden önce alan adına sahip olduğunu kanıtlama protokolü.

### OAuth2
**TR:** OAuth2

The delegated authorisation standard: a user grants an app limited access without handing over their password.

Yetki devri standardı: kullanıcı parolasını vermeden bir uygulamaya sınırlı erişim verir.

### OIDC
**TR:** OIDC (OpenID Connect)

An identity layer on top of OAuth2. OAuth2 answers what may this app do; OIDC also answers who is this person.

OAuth2'nin üstüne kimlik katmanı. OAuth2 bu uygulama neyi yapabilir sorusunu, OIDC ayrıca bu kişi kim sorusunu yanıtlar.

### PKCE
**TR:** PKCE

An extra proof step that stops a stolen authorization code being redeemed by an attacker. Mandatory for public clients.

Çalınan bir authorization code'un saldırgan tarafından kullanılmasını engelleyen ek kanıt adımı. Public client'lar için zorunlu.

### Rate limiting
**TR:** Hız sınırlama

Capping how many requests one caller may make in a window. Protects against abuse and against accidental self-inflicted load.

Bir çağıranın belirli sürede yapabileceği istek sayısını sınırlamak. Hem kötüye kullanıma hem de kazara kendi kendine yüklenmeye karşı korur.

### RBAC
**TR:** RBAC (rol tabanlı erişim)

Permissions attached to roles, roles attached to users. Kubernetes has its own RBAC, separate from Keycloak's.

İzinler rollere, roller kullanıcılara bağlanır. Kubernetes'in Keycloak'tan bağımsız kendi RBAC'i vardır.

### Realm
**TR:** Realm

An isolated tenant inside Keycloak: its own users, roles, clients and signing keys.

Keycloak içinde izole bir kiracı: kendi kullanıcıları, rolleri, client'ları ve imzalama anahtarları.

> **In XenOpsBase:** Defined declaratively in git and imported — never edited in the admin UI, because a rebuild would erase it.  
> **XenOpsBase'de:** Git'te bildirimsel olarak tanımlanıp içeri aktarılıyor — admin arayüzünden asla düzenlenmiyor, çünkü yeniden kurulumda silinirdi.

### Refresh token
**TR:** Refresh token (yenileme jetonu)

A longer-lived token used to get a new access token without asking the user to log in again.

Kullanıcıya tekrar giriş yaptırmadan yeni access token almak için kullanılan, daha uzun ömürlü token.

### Resource server
**TR:** Resource server

An API that accepts tokens and validates them, rather than logging users in itself.

Kullanıcı girişi yaptırmayan, sadece token kabul edip doğrulayan API.

> **In XenOpsBase:** The core service is one; the gateway is both a client and a resource server.  
> **XenOpsBase'de:** core servisi budur; gateway hem client hem resource server'dır.

### Secret rotation
**TR:** Sır rotasyonu

Replacing a credential on a schedule or after exposure, without downtime. If you cannot rotate it, you do not really control it.

Bir kimlik bilgisini plana göre ya da sızıntı sonrası, kesinti olmadan değiştirmek. Döndüremiyorsan aslında kontrol etmiyorsundur.

### Service-to-service auth
**TR:** Servisten servise kimlik doğrulama

How one backend proves who it is to another when no human is involved — usually the client credentials grant.

Ortada insan yokken bir arka ucun diğerine kim olduğunu kanıtlaması — genelde client credentials akışıyla.

### SOPS
**TR:** SOPS

Encrypts only the values in a YAML file, leaving keys and structure readable. So a secret can live in git and still diff usefully.

YAML dosyasında sadece değerleri şifreler, anahtarları ve yapıyı okunur bırakır. Böylece bir sır git'te yaşayabilir ve diff'i hâlâ anlamlı olur.

> **In XenOpsBase:** ADR-0003. Config in .sops.yaml, enforced by make check-secrets and the secrets workflow.  
> **XenOpsBase'de:** ADR-0003. Ayarlar .sops.yaml'da; make check-secrets ve secrets workflow'u bunu zorunlu kılıyor.

### Threat model
**TR:** Tehdit modeli

Writing down who might attack this, how, and what you are deliberately not defending against. A document, not a tool.

Kimin, nasıl saldırabileceğini ve neye karşı bilinçli olarak savunma yapmadığını yazıya dökmek. Araç değil, belge.

> **In XenOpsBase:** T-8.1.  
> **XenOpsBase'de:** T-8.1.

### TLS
**TR:** TLS

The encryption under HTTPS. A certificate proves the server is who the hostname says it is.

HTTPS'in altındaki şifreleme. Sertifika, sunucunun alan adının iddia ettiği kişi olduğunu kanıtlar.

### Token relay
**TR:** Token relay (jeton aktarımı)

The gateway forwarding the user's token onward to the core service, so the identity of the real caller survives the hop.

Gateway'in kullanıcının token'ını core servise iletmesi; böylece asıl çağıranın kimliği sıçramadan sağ çıkar.

> **In XenOpsBase:** T-3.2 and T-3.5.  
> **XenOpsBase'de:** T-3.2 ve T-3.5.

### WAF
**TR:** WAF (web uygulama güvenlik duvarı)

A filter in front of your app that blocks known attack patterns before they reach it.

Uygulamanın önünde duran, bilinen saldırı desenlerini ulaşmadan engelleyen filtre.


<a id="net"></a>

## Ağ & edge / Network & edge

### A / CNAME record
**TR:** A / CNAME kaydı

An A record points a name at an IP address. A CNAME points a name at another name.

A kaydı bir adı IP adresine yönlendirir. CNAME ise bir adı başka bir ada yönlendirir.

### Bastion / jump host
**TR:** Bastion / atlama sunucusu

The one hardened machine you are allowed to SSH into, from which you reach everything else.

SSH ile girmene izin verilen tek sıkılaştırılmış makine; diğer her şeye oradan ulaşırsın.

### Cloudflare proxy (orange cloud)
**TR:** Cloudflare proxy (turuncu bulut)

Traffic goes through Cloudflare instead of straight to your server. You get caching, TLS and WAF; your real IP stays hidden.

Trafik doğrudan sunucuna değil Cloudflare üzerinden gider. Önbellek, TLS ve WAF kazanırsın; gerçek IP'n gizli kalır.

### Cloudflare Tunnel / cloudflared
**TR:** Cloudflare Tunnel / cloudflared

An agent inside the cluster dials out to Cloudflare and holds the connection open. Traffic arrives through that tunnel, so no inbound port is ever opened.

Küme içindeki bir ajan Cloudflare'e dışarı doğru bağlanır ve bağlantıyı açık tutar. Trafik bu tünelden gelir; hiçbir zaman içeri açık port olmaz.

> **In XenOpsBase:** Why there is no public load balancer here, and why DNS survives a cluster rebuild unchanged.  
> **XenOpsBase'de:** Burada neden herkese açık load balancer olmadığının ve DNS'in küme yeniden kurulunca neden değişmediğinin sebebi.

### DNS
**TR:** DNS

The phone book turning a hostname into an address.

Alan adını adrese çeviren telefon rehberi.

### Edge
**TR:** Edge (kenar)

The outermost layer where traffic from the internet first meets your system, before it reaches anything you run.

İnternetten gelen trafiğin, senin çalıştırdığın hiçbir şeye ulaşmadan önce ilk karşılaştığı en dış katman.

> **In XenOpsBase:** infra/terraform/edge — Cloudflare DNS and the tunnel.  
> **XenOpsBase'de:** infra/terraform/edge — Cloudflare DNS ve tünel.

### Firewall rule
**TR:** Güvenlik duvarı kuralı

An allow or deny decision on traffic by port, protocol and source.

Trafiğe port, protokol ve kaynağa göre izin verme ya da reddetme kararı.

> **In XenOpsBase:** make verify-exposure probes every public address and asserts only intended ports answer.  
> **XenOpsBase'de:** make verify-exposure her genel adresi yoklar ve sadece istenen portların yanıt verdiğini doğrular.

### Ingress vs egress traffic
**TR:** Gelen (ingress) vs giden (egress) trafik

Ingress is traffic coming in from outside; egress is traffic your system sends out. Closing all ingress is possible; closing all egress is not.

Ingress dışarıdan gelen, egress ise sistemin dışarı gönderdiği trafiktir. Tüm ingress'i kapatmak mümkündür; tüm egress'i kapatmak değildir.

### Load balancer
**TR:** Yük dengeleyici

Spreads incoming traffic across several backends. Deliberately absent here — the tunnel replaces it and costs nothing when idle.

Gelen trafiği birkaç arka uca dağıtır. Burada bilinçli olarak yok — tünel yerini alıyor ve boştayken hiç maliyeti yok.

### NAT
**TR:** NAT

Lets machines with only private addresses reach the internet through one shared public address.

Sadece özel adresi olan makinelerin, paylaşılan tek bir genel adres üzerinden internete çıkmasını sağlar.

### Overlay network
**TR:** Kaplama ağı (overlay)

A virtual network built on top of the real one, so machines anywhere behave as if they share a LAN.

Gerçek ağın üzerine kurulan sanal ağ; farklı yerlerdeki makineler aynı yerel ağdaymış gibi davranır.

### Public endpoint
**TR:** Genel uç nokta

Any address reachable from the open internet. Every one of them is attack surface, so the count should be justified and small.

Açık internetten erişilebilen her adres. Her biri saldırı yüzeyidir; sayısı gerekçeli ve küçük olmalı.

### QUIC
**TR:** QUIC

A UDP-based transport used by HTTP/3 and by Cloudflare Tunnel. If UDP is blocked, the tunnel silently falls back or fails.

HTTP/3'ün ve Cloudflare Tunnel'ın kullandığı, UDP tabanlı taşıma protokolü. UDP engellenirse tünel sessizce geri düşer ya da bağlanamaz.

> **In XenOpsBase:** Called out in the ingress-tls runbook as a firewall gotcha.  
> **XenOpsBase'de:** ingress-tls runbook'unda güvenlik duvarı tuzağı olarak özellikle belirtilmiş.

### Reverse proxy
**TR:** Ters vekil sunucu

A server that receives requests on behalf of others and forwards them, deciding routing, TLS and headers along the way.

İstekleri başkaları adına alıp ileten, yönlendirmeye, TLS'e ve başlıklara yol boyunca karar veren sunucu.

### Tailscale / WireGuard
**TR:** Tailscale / WireGuard

WireGuard is a fast modern VPN protocol; Tailscale is a managed mesh built on it. Nodes talk over encrypted private addresses with nothing exposed publicly.

WireGuard hızlı ve modern bir VPN protokolü; Tailscale ise onun üzerine kurulu yönetilen bir ağ örgüsü. Node'lar şifreli özel adresler üzerinden konuşur, dışarı hiçbir şey açılmaz.

> **In XenOpsBase:** ADR-0006. Also the cause of T-1.10, where the Hetzner CCM stopped recognising nodes.  
> **XenOpsBase'de:** ADR-0006. Ayrıca Hetzner CCM'in node'ları tanımamasına yol açan T-1.10'un da sebebi.

### Zone
**TR:** Zone (DNS bölgesi)

One domain and all its records, managed as a unit.

Bir alan adı ve tüm kayıtları, tek birim olarak yönetilir.

> **In XenOpsBase:** The runbook warns about the shared-zone hazard: Terraform managing records in a zone that also holds records it did not create.  
> **XenOpsBase'de:** Runbook paylaşılan bölge tehlikesine dikkat çekiyor: Terraform'un, kendi yaratmadığı kayıtların da bulunduğu bir bölgeyi yönetmesi.


<a id="data"></a>

## Veri & veritabanı / Data & database

### barman-cloud
**TR:** barman-cloud

The plugin CloudNativePG uses to push base backups and WAL to S3-compatible storage.

CloudNativePG'nin temel yedekleri ve WAL'ı S3 uyumlu depolamaya göndermek için kullandığı eklenti.

### Base backup
**TR:** Temel yedek (base backup)

A full physical copy of the database at one instant. WAL replays forward from it.

Veritabanının bir andaki tam fiziksel kopyası. WAL bu noktadan ileri doğru oynatılır.

### Checksum drift
**TR:** Checksum sapması

Editing a migration file that has already run. Flyway detects the mismatch and should refuse to start rather than pretend.

Zaten çalışmış bir migration dosyasını düzenlemek. Flyway uyuşmazlığı fark eder ve numara yapmak yerine başlamayı reddetmelidir.

### CloudNativePG
**TR:** CloudNativePG

A Kubernetes operator that runs Postgres properly: primary and replicas, failover, backups, WAL archiving, all declared as YAML.

Postgres'i düzgün çalıştıran Kubernetes operatörü: birincil ve kopyalar, devretme, yedekler, WAL arşivleme — hepsi YAML ile beyan edilir.

### ddl-auto: validate
**TR:** ddl-auto: validate

Tells Hibernate to check that the schema matches the entities and fail loudly if not — instead of silently altering tables in production.

Hibernate'e şemanın entity'lerle eşleştiğini kontrol etmesini, eşleşmiyorsa yüksek sesle hata vermesini söyler — üretimde tabloları sessizce değiştirmek yerine.

> **In XenOpsBase:** T-3.6 makes this the setting from commit one.  
> **XenOpsBase'de:** T-3.6 bunu ilk commit'ten itibaren geçerli ayar yapıyor.

### Distributed lock
**TR:** Dağıtık kilit

A lock several instances of your app share, so a scheduled job runs once across the whole cluster instead of once per pod.

Uygulamanın birden çok kopyasının paylaştığı kilit; zamanlanmış bir iş pod başına değil, küme genelinde bir kez çalışır.

### Failover
**TR:** Failover (devretme)

Promoting a replica to primary when the primary dies. Automatic here; the point is that it is tested, not assumed.

Primary öldüğünde bir replica'yı primary'ye yükseltmek. Burada otomatik; asıl mesele varsayılması değil test edilmesi.

### Flyway
**TR:** Flyway

Applies numbered SQL migration files in order and records which have run, so every environment reaches the same schema by the same path.

Numaralı SQL migration dosyalarını sırayla uygular ve hangilerinin çalıştığını kaydeder; böylece her ortam aynı şemaya aynı yoldan ulaşır.

> **In XenOpsBase:** src/main/resources/db/migration/V1__baseline.sql  
> **XenOpsBase'de:** src/main/resources/db/migration/V1__baseline.sql

### HikariCP / connection pool
**TR:** HikariCP / bağlantı havuzu

Opening a database connection is expensive, so a pool keeps a set of them open and hands them out. Pool size is a real capacity limit.

Veritabanı bağlantısı açmak pahalıdır; havuz bir grubunu açık tutup dağıtır. Havuz boyutu gerçek bir kapasite sınırıdır.

### JPA / Hibernate
**TR:** JPA / Hibernate

JPA is the Java standard for mapping objects to tables; Hibernate is the implementation that does it.

JPA, nesneleri tablolara eşlemek için Java standardı; Hibernate ise bunu yapan uygulamadır.

### Migration
**TR:** Migration (şema göçü)

One versioned, forward-only change to the database schema.

Veritabanı şemasında sürümlenmiş, sadece ileri giden tek bir değişiklik.

### ObjectStore / ScheduledBackup
**TR:** ObjectStore / ScheduledBackup

CloudNativePG custom resources: one says where backups go, the other says how often to take them.

CloudNativePG özel kaynakları: biri yedeklerin nereye gideceğini, diğeri ne sıklıkla alınacağını söyler.

### PITR
**TR:** PITR (zamanda bir noktaya geri dönüş)

Restoring the database to any chosen second, not just to the last nightly backup. The defence against a bad migration or a wrong DELETE.

Veritabanını sadece son gecelik yedeğe değil, seçtiğin herhangi bir saniyeye geri getirmek. Hatalı bir migration ya da yanlış bir DELETE'e karşı savunma.

> **In XenOpsBase:** T-7.4 — one of the three gaps the prior project admitted it had.  
> **XenOpsBase'de:** T-7.4 — önceki projenin itiraf ettiği üç boşluktan biri.

### PostgreSQL
**TR:** PostgreSQL

The relational database this project uses.

Bu projenin kullandığı ilişkisel veritabanı.

### Presigned URL
**TR:** İmzalı geçici URL

A time-limited link that lets a browser upload or download an object directly, without the file passing through your application.

Tarayıcının bir nesneyi doğrudan yükleyip indirmesini sağlayan, süresi dolan bağlantı; dosya uygulamanın içinden geçmez.

### Primary and replica
**TR:** Primary ve replica

The primary accepts writes; replicas stream a copy and can take over. Replication is availability, not backup.

Primary yazma alır; replica'lar kopyayı akıtır ve devralabilir. Replikasyon yedek değil, erişilebilirliktir.

### Redis / Valkey
**TR:** Redis / Valkey

An in-memory data store used for caching, rate-limit counters and distributed locks. Valkey is the open-source fork of Redis.

Önbellek, hız sınırı sayaçları ve dağıtık kilitler için kullanılan bellek içi veri deposu. Valkey, Redis'in açık kaynak çatallamasıdır.

> **In XenOpsBase:** T-2.11, still in the backlog.  
> **XenOpsBase'de:** T-2.11, hâlâ backlog'da.

### Restore drill
**TR:** Geri yükleme tatbikatı

Actually restoring from backup on a schedule and checking the result. A backup you have never restored is a hypothesis.

Yedekten düzenli aralıklarla gerçekten geri yükleyip sonucu kontrol etmek. Hiç geri yüklemediğin yedek bir varsayımdır.

> **In XenOpsBase:** T-7.3, nightly and automated.  
> **XenOpsBase'de:** T-7.3, gecelik ve otomatik.

### RPO
**TR:** RPO (kabul edilebilir veri kaybı)

How much data you can afford to lose, measured in time. Five-minute RPO means an outage may cost you five minutes of writes.

Kaybetmeyi göze alabileceğin veri miktarı, zaman cinsinden. Beş dakikalık RPO, bir kesintinin sana beş dakikalık yazmaya mal olabileceği demektir.

### RTO
**TR:** RTO (kabul edilebilir kesinti süresi)

How long you can afford to be down before you are back up.

Tekrar ayağa kalkana kadar kapalı kalmayı göze alabileceğin süre.

> **In XenOpsBase:** T-7.1 requires both numbers written down per component, not vaguely felt.  
> **XenOpsBase'de:** T-7.1 her iki sayının da bileşen başına yazılı olmasını istiyor, hissedilmesini değil.

### S3 API
**TR:** S3 API

The HTTP interface for object storage: PUT an object at a key, GET it back, list by prefix. Using only this keeps you portable.

Nesne depolamanın HTTP arayüzü: bir anahtara PUT et, GET ile geri al, önekle listele. Sadece bunu kullanmak seni taşınabilir tutar.

> **In XenOpsBase:** T-3.7 builds the document module on it, no provider SDK.  
> **XenOpsBase'de:** T-3.7 doküman modülünü bunun üzerine kuruyor, sağlayıcıya özel SDK yok.

### WAL
**TR:** WAL (write-ahead log)

Postgres writes every change to a sequential log before applying it. Replay that log over a base backup and you can reconstruct any moment in time.

Postgres her değişikliği uygulamadan önce sıralı bir kütüğe yazar. Bu kütüğü bir temel yedeğin üzerine oynatınca herhangi bir ana geri dönebilirsin.

### WAL archiving
**TR:** WAL arşivleme

Continuously shipping those WAL files to object storage as they are produced. This is what turns nightly backups into point-in-time recovery.

Üretildikçe bu WAL dosyalarını sürekli nesne depolamaya göndermek. Gecelik yedekleri zamanda bir noktaya dönüşe çeviren şey budur.

> **In XenOpsBase:** T-2.4, via the barman-cloud plugin into a Hetzner bucket.  
> **XenOpsBase'de:** T-2.4, barman-cloud eklentisiyle bir Hetzner bucket'ına.


<a id="app"></a>

## Uygulama (Java / Spring) / Application (Java / Spring)

### Actuator
**TR:** Actuator

Spring Boot's built-in operational endpoints: health, readiness, metrics, environment. What Kubernetes probes and Prometheus scrape.

Spring Boot'un yerleşik işletim uçları: sağlık, hazır olma, metrikler, ortam. Kubernetes probe'larının ve Prometheus'un baktığı yer.

### AOP / aspect
**TR:** AOP / aspect

Injecting behaviour like logging or timing around many methods without editing each one.

Loglama ya da süre ölçme gibi davranışları, her metodu tek tek düzenlemeden birçok metodun etrafına eklemek.

### Auditing
**TR:** Denetim kaydı (auditing)

Automatically recording who created or changed a row and when.

Bir satırı kimin ne zaman yarattığını veya değiştirdiğini otomatik kaydetmek.

> **In XenOpsBase:** AbstractAuditingEntity.java and SpringSecurityAuditorAware.java.  
> **XenOpsBase'de:** AbstractAuditingEntity.java ve SpringSecurityAuditorAware.java.

### Auto-configuration
**TR:** Otomatik yapılandırma

Spring configuring a component for you because it saw the library on the classpath. Powerful, and the usual reason something works that you never wired up.

Spring'in, sınıf yolunda kütüphaneyi gördüğü için bir bileşeni senin yerine yapılandırması. Güçlüdür ve hiç bağlamadığın bir şeyin çalışmasının nedeni genelde budur.

### Bean
**TR:** Bean

An object Spring creates and manages for you, and injects wherever it is needed.

Spring'in senin için yarattığı, yönettiği ve gerektiği yere enjekte ettiği nesne.

### Bulkhead
**TR:** Bulkhead (bölme)

Capping how many concurrent calls one dependency may consume, so one slow backend cannot exhaust the whole thread pool.

Tek bir bağımlılığın kullanabileceği eşzamanlı çağrı sayısını sınırlamak; böylece yavaş bir arka uç tüm thread havuzunu tüketemez.

### Circuit breaker
**TR:** Devre kesici

After enough failures it stops calling a sick dependency at all and fails fast, giving the dependency room to recover instead of finishing it off.

Yeterince hata sonrası hasta bağımlılığı aramayı tamamen bırakır ve hızlı hata döner; böylece bağımlılığı bitirmek yerine toparlanmasına alan tanır.

### Detach from the generator
**TR:** Jeneratörden kopmak

Deleting the generator's markers and machinery so the code is simply yours, and no future regeneration can overwrite your work.

Jeneratörün işaretlerini ve makinesini silip kodun sadece sana ait olmasını sağlamak; böylece ileride yeniden üretim işini ezemez.

> **In XenOpsBase:** T-3.4. GeneratedByJHipster.java and .yo-rc.json are the markers.  
> **XenOpsBase'de:** T-3.4. İşaretler GeneratedByJHipster.java ve .yo-rc.json.

### DTO
**TR:** DTO (veri taşıma nesnesi)

A shape defined for the API boundary, separate from the database entity, so your table layout is not your public contract.

API sınırı için tanımlanan, veritabanı entity'sinden ayrı yapı; böylece tablo düzenin genel sözleşmen olmaz.

### Entity
**TR:** Entity (varlık)

A Java class mapped to a database table.

Bir veritabanı tablosuna eşlenmiş Java sınıfı.

### HTTP contract
**TR:** HTTP sözleşmesi

The rules every endpoint follows: error shape, pagination, filtering, correlation IDs, status codes. Decided once, not per endpoint.

Her ucun uyduğu kurallar: hata biçimi, sayfalama, filtreleme, korelasyon kimlikleri, durum kodları. Uç başına değil, bir kez kararlaştırılır.

> **In XenOpsBase:** T-3.8. RFC 7807 problem details is the usual choice for the error shape.  
> **XenOpsBase'de:** T-3.8. Hata biçimi için genelde RFC 7807 problem details seçilir.

### Jackson
**TR:** Jackson

The library turning Java objects into JSON and back. Most surprising API output is a Jackson configuration question.

Java nesnelerini JSON'a ve geri çeviren kütüphane. Beklenmedik API çıktılarının çoğu bir Jackson ayarı meselesidir.

### JDL
**TR:** JDL (JHipster Domain Language)

The small language describing the applications and entities JHipster should generate.

JHipster'ın üreteceği uygulamaları ve entity'leri tarif eden küçük dil.

> **In XenOpsBase:** services/xenopsbase.jdl  
> **XenOpsBase'de:** services/xenopsbase.jdl

### JHipster
**TR:** JHipster

A code generator that scaffolds a Spring Boot application with security, persistence, build and CI already wired.

Güvenliği, kalıcılığı, derlemeyi ve CI'ı hazır bağlanmış bir Spring Boot uygulaması iskeleti üreten kod jeneratörü.

> **In XenOpsBase:** Used to bootstrap, then abandoned on purpose — see the spike doc and T-3.4.  
> **XenOpsBase'de:** Başlangıç için kullanıldı, sonra bilinçli olarak terk ediliyor — spike belgesine ve T-3.4'e bak.

### MapStruct
**TR:** MapStruct

Generates the boring entity-to-DTO conversion code at compile time instead of you writing it by hand.

Sıkıcı entity-DTO dönüşüm kodunu elle yazmak yerine derleme anında üretir.

### Multi-tenancy
**TR:** Çok kiracılılık

One deployment serving several isolated customers. The isolation has to be designed in early or retrofitted painfully.

Tek kurulumun birbirinden izole birçok müşteriye hizmet vermesi. İzolasyon ya erkenden tasarlanır ya da sonradan acıyla eklenir.

### NullPointerException
**TR:** NullPointerException

Java's error for using a value that is not there. In token handling it almost always means an optional claim was assumed to be mandatory.

Java'nın, olmayan bir değeri kullanınca verdiği hata. Token işlemede neredeyse her zaman isteğe bağlı bir claim'in zorunlu sanıldığı anlamına gelir.

### OpenAPI / springdoc / Swagger UI
**TR:** OpenAPI / springdoc / Swagger UI

OpenAPI is the machine-readable description of your API; springdoc generates it from your code; Swagger UI renders it as a browsable page.

OpenAPI API'nin makine okur tanımıdır; springdoc bunu kodundan üretir; Swagger UI de gezilebilir bir sayfa olarak gösterir.

> **In XenOpsBase:** T-3.11 also generates typed clients from it.  
> **XenOpsBase'de:** T-3.11 ayrıca bundan tipli istemciler üretiyor.

### Outbox pattern
**TR:** Outbox deseni

Writing the event into the same database transaction as the data, then publishing it separately. Stops the state changing without the event, or the reverse.

Olayı, veriyle aynı veritabanı işlemine yazıp sonra ayrı olarak yayımlamak. Durum değişip olay gitmemesini ya da tersini engeller.

### Profile
**TR:** Profile (profil)

A named set of configuration switched on at startup: application-dev.yml versus application-prod.yml.

Başlangıçta devreye alınan, adlandırılmış yapılandırma seti: application-dev.yml ile application-prod.yml.

### Repository
**TR:** Repository

The interface you query the database through. Spring Data writes the implementation from the method names.

Veritabanını sorguladığın arayüz. Spring Data, metot adlarından uygulamayı kendi yazar.

### Resilience4j
**TR:** Resilience4j

The library providing circuit breakers, retries, timeouts, bulkheads and rate limiters for calls between services.

Servisler arası çağrılar için devre kesici, yeniden deneme, zaman aşımı, bölme ve hız sınırlayıcı sağlayan kütüphane.

### REST endpoint
**TR:** REST uç noktası

One URL plus HTTP method your API answers on.

API'nin yanıt verdiği tek bir URL ve HTTP metodu.

### Route / predicate / filter
**TR:** Route / predicate / filter

A route is where a request goes; a predicate decides whether this route matches; a filter changes the request or response on the way through.

Route isteğin nereye gideceğidir; predicate bu rotanın eşleşip eşleşmediğine karar verir; filter geçerken isteği ya da yanıtı değiştirir.

### Soft delete
**TR:** Yumuşak silme

Marking a row deleted instead of removing it, so it can be recovered and audited.

Satırı kaldırmak yerine silinmiş olarak işaretlemek; böylece geri alınabilir ve denetlenebilir.

### Spring Boot
**TR:** Spring Boot

The Java framework both services are built on. It wires the application together from dependencies you declare, with sane defaults you can override.

Her iki servisin de üzerine kurulduğu Java çatısı. Uygulamayı, tanımladığın bağımlılıklardan makul varsayılanlarla kendi kurar; istersen ezersin.

### Spring Cloud Gateway
**TR:** Spring Cloud Gateway

The reactive API gateway. Routes matched by predicates, transformed by filters, forwarded to backends. Handles login and token relay here.

Reaktif API ağ geçidi. Rotalar predicate'lerle eşleşir, filtrelerle dönüştürülür, arka uçlara iletilir. Burada girişi ve token aktarımını o üstleniyor.

### Starter
**TR:** Starter

A curated dependency bundle. Adding spring-boot-starter-oauth2-resource-server pulls in everything needed to validate tokens.

Derli toplu bağımlılık paketi. spring-boot-starter-oauth2-resource-server eklemek, token doğrulamak için gereken her şeyi getirir.

### Timeout
**TR:** Zaman aşımı

A hard limit on how long you wait. A call with no timeout is a resource leak waiting to happen.

Ne kadar bekleyeceğinin katı sınırı. Zaman aşımı olmayan çağrı, gerçekleşmeyi bekleyen bir kaynak sızıntısıdır.

### WebFlux vs Web MVC
**TR:** WebFlux vs Web MVC

MVC gives each request a thread and blocks. WebFlux is non-blocking on a few threads — better for a proxy, but one blocking call anywhere can stall everything.

MVC her isteğe bir thread verir ve bloklar. WebFlux az sayıda thread üzerinde bloklamadan çalışır — vekil için daha iyi, ama tek bir bloklayan çağrı her şeyi durdurabilir.

> **In XenOpsBase:** Gateway is WebFlux; core is MVC. That is why the gateway has BlockHound in its test dependencies.  
> **XenOpsBase'de:** Gateway WebFlux, core MVC. Gateway'in test bağımlılıklarında BlockHound olmasının sebebi bu.


<a id="obs"></a>

## Gözlemlenebilirlik / Observability

### Alert rule / Alertmanager
**TR:** Alarm kuralı / Alertmanager

A rule fires when a query crosses a threshold for a duration; Alertmanager decides who gets told, how, and what is silenced.

Bir sorgu belirli süre boyunca eşiği aşınca kural tetiklenir; Alertmanager kime, nasıl haber verileceğine ve neyin susturulacağına karar verir.

> **In XenOpsBase:** T-7.6, plus the backup alerts already in platform/envs/dev/observability/.  
> **XenOpsBase'de:** T-7.6, ayrıca platform/envs/dev/observability/ içinde hâlihazırda olan yedek alarmları.

### Cardinality
**TR:** Kardinalite

How many distinct label combinations a metric has. Putting a user ID in a label is the classic way to melt Prometheus.

Bir metriğin kaç farklı etiket kombinasyonu olduğu. Etikete kullanıcı kimliği koymak, Prometheus'u eritmenin klasik yoludur.

### Collector / Grafana Alloy
**TR:** Collector / Grafana Alloy

The agent that receives telemetry from your apps, batches and transforms it, and forwards it to the right backend.

Uygulamalarından telemetriyi alan, toplayıp dönüştüren ve doğru arka uca ileten ajan.

### Dashboards as code
**TR:** Kod olarak panolar

Dashboards defined as files in git and provisioned on startup, instead of clicked together in the UI and lost on rebuild.

Panoların arayüzde tıklanarak yapılıp yeniden kurulumda kaybolması yerine, git'te dosya olarak tanımlanıp açılışta yüklenmesi.

> **In XenOpsBase:** T-2.6. In the README table Grafana dashboards at runtime are explicitly on the disposable side.  
> **XenOpsBase'de:** T-2.6. README tablosunda çalışma anındaki Grafana panoları açıkça atılabilir tarafta.

### Grafana
**TR:** Grafana

The dashboard and visualisation layer over all of it.

Hepsinin üzerindeki pano ve görselleştirme katmanı.

### LGTM stack
**TR:** LGTM yığını

Grafana's set: Loki for logs, Grafana for dashboards, Tempo for traces, Mimir or Prometheus for metrics.

Grafana'nın seti: loglar için Loki, panolar için Grafana, izler için Tempo, metrikler için Mimir ya da Prometheus.

### Log
**TR:** Log (kütük)

A timestamped line describing one event. Detailed, expensive at volume.

Tek bir olayı anlatan, zaman damgalı satır. Ayrıntılıdır, hacim büyüyünce pahalıdır.

### Loki
**TR:** Loki

A log store that indexes only labels and pushes the log content itself into object storage — which is why it is cheap.

Sadece etiketleri indeksleyen, log içeriğini nesne depolamaya gönderen log deposu — ucuz olmasının sebebi bu.

### Metric
**TR:** Metrik

A number sampled over time: requests per second, memory in use, queue depth. Cheap to store, no detail about individual events.

Zaman içinde örneklenen sayı: saniyedeki istek, kullanılan bellek, kuyruk derinliği. Saklaması ucuzdur, tekil olaylar hakkında ayrıntı vermez.

### Micrometer
**TR:** Micrometer

The metrics and tracing facade inside Spring Boot. You instrument once; it exports to Prometheus, Zipkin or OTel.

Spring Boot içindeki metrik ve iz cephesi. Bir kez enstrümante edersin; Prometheus, Zipkin ya da OTel'e o aktarır.

### Observability
**TR:** Gözlemlenebilirlik

Being able to answer new questions about a running system without shipping new code. Built from metrics, logs and traces.

Çalışan bir sistem hakkında yeni kod göndermeden yeni sorular yanıtlayabilmek. Metrik, log ve iz üçlüsünden kurulur.

### OpenTelemetry (OTel)
**TR:** OpenTelemetry (OTel)

The vendor-neutral standard for producing metrics, logs and traces, so you can change backend without re-instrumenting your code.

Metrik, log ve iz üretmek için satıcıdan bağımsız standart; arka ucu değiştirdiğinde kodunu yeniden enstrümante etmen gerekmez.

### Postmortem
**TR:** Olay sonrası inceleme

A blameless written account after an incident: what happened, why, and what changes so it does not happen the same way twice.

Olaydan sonra suçlamasız yazılı döküm: ne oldu, neden oldu, aynı şekilde tekrarlanmaması için ne değişiyor.

### Prometheus
**TR:** Prometheus

The metrics database. It scrapes an HTTP endpoint on each target on a schedule and stores the numbers as time series.

Metrik veritabanı. Her hedefteki bir HTTP ucunu düzenli aralıklarla toplar ve sayıları zaman serisi olarak saklar.

### PromQL
**TR:** PromQL

The query language for Prometheus. Dashboards and alert rules are both written in it.

Prometheus'un sorgu dili. Panolar da alarm kuralları da bununla yazılır.

### Scrape / exporter
**TR:** Scrape / exporter

Scraping is Prometheus pulling metrics. An exporter is a small adapter that exposes something else's numbers in the format Prometheus expects.

Scrape, Prometheus'un metrikleri çekmesidir. Exporter ise başka bir şeyin sayılarını Prometheus'un beklediği biçimde sunan küçük adaptördür.

### SLI / SLO / error budget
**TR:** SLI / SLO / hata bütçesi

An SLI is the measurement (99.2% of requests succeeded). An SLO is the target (99.5%). The error budget is the gap you are allowed to spend.

SLI ölçümdür (isteklerin %99,2'si başarılı). SLO hedeftir (%99,5). Hata bütçesi ise harcamana izin verilen farktır.

### Tempo
**TR:** Tempo

The trace store, on the same object-storage-backed model as Loki.

İz deposu; Loki ile aynı nesne depolama tabanlı modeli kullanır.

### Trace and span
**TR:** İz (trace) ve span

A trace follows one request across every service; each span is one step within it, with its own duration. This is how you find where the time went.

Trace tek bir isteği tüm servisler boyunca takip eder; her span onun içindeki bir adımdır ve kendi süresi vardır. Zamanın nereye gittiğini böyle bulursun.


<a id="test"></a>

## Test & kalite / Testing & quality

### ArchUnit
**TR:** ArchUnit

Tests your architecture rules as code: the web layer may not call repositories directly, domain may not import Spring, and so on.

Mimari kurallarını kod olarak test eder: web katmanı repository'leri doğrudan çağıramaz, domain Spring'i import edemez gibi.

### Chaos engineering
**TR:** Kaos mühendisliği

Deliberately breaking things in a controlled way — killing a pod, adding latency — to check the system degrades the way you claimed.

Kontrollü şekilde bilerek bir şeyler bozmak — pod öldürmek, gecikme eklemek — sistemin iddia ettiğin gibi bozulup bozulmadığını görmek için.

### Checkstyle / Spotless / Prettier
**TR:** Checkstyle / Spotless / Prettier

Checkstyle enforces style rules; Spotless and Prettier rewrite the code into the agreed format automatically.

Checkstyle stil kurallarını zorunlu kılar; Spotless ve Prettier kodu üzerinde anlaşılan biçime otomatik olarak yeniden yazar.

### Contract test
**TR:** Sözleşme testi

Checks that the caller's expectations and the provider's actual API still agree, so a breaking change is caught in CI rather than in production.

Çağıranın beklentisiyle sağlayıcının gerçek API'sinin hâlâ uyuştuğunu kontrol eder; kırıcı değişiklik üretimde değil CI'da yakalanır.

> **In XenOpsBase:** T-5.4, between gateway and core.  
> **XenOpsBase'de:** T-5.4, gateway ile core arasında.

### Coverage / JaCoCo
**TR:** Kapsam / JaCoCo

The percentage of code executed by tests. A useful floor, a terrible target — 100% coverage proves the lines ran, not that they are correct.

Testlerin çalıştırdığı kod yüzdesi. İyi bir taban, kötü bir hedef — %100 kapsam satırların çalıştığını kanıtlar, doğru olduklarını değil.

### Cucumber / BDD
**TR:** Cucumber / BDD

Tests written as Given-When-Then scenarios in near-plain language, executed against step definitions in code.

Neredeyse düz dilde Given-When-Then senaryoları olarak yazılan, koddaki adım tanımlarıyla çalıştırılan testler.

### Devcontainer
**TR:** Devcontainer

A container definition for the development environment itself, so every contributor gets identical tools without installing them.

Geliştirme ortamının kendisi için konteyner tanımı; her katkıcı hiçbir şey kurmadan aynı araçlara sahip olur.

### End-to-end (E2E) test
**TR:** Uçtan uca test

Drives the whole deployed system the way a user would, through the real front door.

Tüm dağıtılmış sistemi, gerçek ön kapıdan, bir kullanıcı gibi sürer.

### Flaky test
**TR:** Kararsız test (flaky)

A test that passes and fails on the same code. Worse than a failing test, because it teaches the team to ignore red.

Aynı kodda bazen geçen bazen kalan test. Kalan testten kötüdür, çünkü ekibe kırmızıyı yok saymayı öğretir.

### Inner loop
**TR:** İç döngü

The edit-run-see-the-result cycle on your own machine. Every second of it is paid many times a day.

Kendi makinende düzenle-çalıştır-sonucu gör döngüsü. Buradaki her saniyenin bedeli günde defalarca ödenir.

> **In XenOpsBase:** T-4.1 targets under five minutes from clone to running.  
> **XenOpsBase'de:** T-4.1'in hedefi: klondan çalışır hale beş dakikanın altında.

### Integration test
**TR:** Entegrasyon testi

Runs against real dependencies — a real Postgres, a real Keycloak — instead of mocks. Slower, and far more convincing.

Sahte nesneler yerine gerçek bağımlılıklara karşı çalışır — gerçek Postgres, gerçek Keycloak. Daha yavaş ama çok daha inandırıcı.

### JUnit 5
**TR:** JUnit 5

The standard Java test framework.

Standart Java test çatısı.

### k6
**TR:** k6

A load-testing tool with scripts written in JavaScript. Establishes what your system does under expected and excessive traffic.

Senaryoları JavaScript ile yazılan yük testi aracı. Sistemin beklenen ve aşırı trafik altında ne yaptığını ortaya koyar.

> **In XenOpsBase:** T-5.6 — the baseline the SLOs are set from.  
> **XenOpsBase'de:** T-5.6 — SLO'ların üzerine kurulduğu temel ölçüm.

### Lint
**TR:** Lint

Any tool that reads code and complains about likely mistakes and bad style without running it.

Kodu çalıştırmadan okuyup olası hataları ve kötü stili söyleyen her araç.

### Pre-commit hook
**TR:** Pre-commit hook

A check git runs before letting a commit through, so formatting and secret scanning happen before CI, not after.

Git'in commit'e izin vermeden önce çalıştırdığı kontrol; biçimlendirme ve sır taraması CI'dan sonra değil önce olur.

### Quality gate
**TR:** Kalite kapısı

A CI threshold that fails the build: coverage below X, new critical issues above zero.

Derlemeyi düşüren CI eşiği: kapsam X'in altında, yeni kritik sorun sıfırın üstünde.

### SAST / DAST
**TR:** SAST / DAST

SAST reads your source for vulnerable patterns. DAST attacks the running application from outside.

SAST kaynağını okuyup zafiyet desenlerini arar. DAST ise çalışan uygulamaya dışarıdan saldırır.

### Slice test
**TR:** Dilim testi (slice test)

Boots only one layer of Spring — just the web layer, or just JPA — instead of the whole application.

Spring'in tüm uygulamasını değil, sadece tek bir katmanını başlatır — yalnız web katmanı ya da yalnız JPA.

### Smoke test
**TR:** Duman testi

A tiny suite run right after a deploy to answer one question: is this fundamentally alive?

Dağıtımdan hemen sonra çalışan minik takım; tek soruya cevap verir: bu şey temelde ayakta mı?

### SonarQube
**TR:** SonarQube

Static analysis over the whole codebase: bugs, code smells, duplication, coverage, tracked over time.

Tüm kod tabanı üzerinde statik analiz: hatalar, kod kokuları, tekrar, kapsam — zaman içinde izlenir.

> **In XenOpsBase:** sonar-project.properties exists in both services.  
> **XenOpsBase'de:** Her iki serviste de sonar-project.properties var.

### Testcontainers
**TR:** Testcontainers

Starts real dependencies as throwaway Docker containers from inside your test run, then destroys them. No shared test database.

Gerçek bağımlılıkları test sırasında tek kullanımlık Docker konteynerleri olarak başlatıp sonra yok eder. Paylaşılan test veritabanı yok.

> **In XenOpsBase:** T-4.2: Postgres, Keycloak and S3.  
> **XenOpsBase'de:** T-4.2: Postgres, Keycloak ve S3.

### Unit test
**TR:** Birim testi

Tests one class in isolation, with its collaborators faked. Fast, and tells you exactly which line is wrong.

Tek bir sınıfı, çevresindekiler taklit edilerek yalıtılmış şekilde test eder. Hızlıdır ve hangi satırın yanlış olduğunu tam söyler.


<a id="proc"></a>

## Süreç, pano & Git / Process, board & Git

### Acceptance criteria
**TR:** Kabul kriterleri

The checklist that decides whether the task is done. Written before the work, so done is not a matter of opinion.

Görevin bitip bitmediğine karar veren kontrol listesi. İşten önce yazılır ki bitti bir görüş meselesi olmasın.

### ADR
**TR:** ADR (mimari karar kaydı)

A short numbered document recording one decision, the alternatives considered, and the consequences accepted. Immutable — superseded, never edited.

Tek bir kararı, değerlendirilen alternatifleri ve kabul edilen sonuçları kaydeden, kısa ve numaralı belge. Değiştirilmez — düzenlenmez, yerine yenisi geçer.

> **In XenOpsBase:** docs/adr/. If you find yourself explaining a choice at length in a PR, it wanted an ADR.  
> **XenOpsBase'de:** docs/adr/. Bir PR'da bir tercihi uzun uzun açıklıyorsan, o aslında bir ADR istiyordu.

### Backlog
**TR:** Backlog (bekleyen iş havuzu)

Not started, and not necessarily startable — it may be blocked by another task.

Başlamamış ve mutlaka başlanabilir de değil — başka bir işe takılı olabilir.

### Blocked
**TR:** Blocked (tıkalı)

Cannot proceed until something else lands. A blocked card should name what it is waiting on.

Başka bir şey tamamlanmadan ilerleyemez. Tıkalı kart neyi beklediğini yazmalıdır.

### Branch
**TR:** Branch (dal)

A parallel line of commits. Here, named after the task: t-2.4/cloudnativepg-wal-archiving.

Paralel commit hattı. Burada görev adıyla anılır: t-2.4/cloudnativepg-wal-archiving.

### Branch protection
**TR:** Dal koruması

Rules on main: no direct pushes, a pull request with green checks required.

main üzerindeki kurallar: doğrudan push yok, yeşil kontrolleri geçmiş bir pull request şart.

### Breaking change
**TR:** Kırıcı değişiklik

A change that breaks existing callers. Marked with ! after the scope or a BREAKING CHANGE footer, and it drives the major version bump.

Mevcut çağıranları bozan değişiklik. Kapsamdan sonra ! ile ya da BREAKING CHANGE dipnotuyla işaretlenir ve ana sürüm artışını tetikler.

### CODEOWNERS
**TR:** CODEOWNERS

A file mapping paths to the people whose review is required for changes there.

Yolları, oradaki değişiklikler için incelemesi zorunlu kişilere eşleyen dosya.

### Conventional Commits
**TR:** Conventional Commits

A message format: type(scope): description. Machine-readable, so changelogs and version bumps can be generated from history.

Mesaj biçimi: type(scope): açıklama. Makine okur olduğu için değişiklik günlükleri ve sürüm artışları geçmişten üretilebilir.

> **In XenOpsBase:** Types: feat, fix, docs, chore, refactor, test, build, ci, perf, revert. Scopes: gateway, core, infra, platform, ci, adr, docs.  
> **XenOpsBase'de:** Tipler: feat, fix, docs, chore, refactor, test, build, ci, perf, revert. Kapsamlar: gateway, core, infra, platform, ci, adr, docs.

### Critical path
**TR:** Kritik yol

The chain of tasks where any delay delays everything. Work these first, in order.

Herhangi bir gecikmenin her şeyi geciktirdiği görev zinciri. Önce ve sırayla bunlar yapılır.

> **In XenOpsBase:** T-0.3 to T-1.1 to T-1.3 to T-2.1 to T-2.4/T-2.5 to T-3.2 to T-7.2.  
> **XenOpsBase'de:** T-0.3, T-1.1, T-1.3, T-2.1, T-2.4/T-2.5, T-3.2, T-7.2.

### Done
**TR:** Done (bitti)

Every acceptance criterion met and verified, or explicitly superseded with the reason recorded.

Her kabul kriteri karşılanmış ve doğrulanmış, ya da sebebi kaydedilerek açıkça geçersiz kılınmış.

### Epic
**TR:** Epic

A large theme grouping many related tasks.

Birçok ilgili işi gruplayan büyük tema.

> **In XenOpsBase:** E0 to E8 here, carried as labels.  
> **XenOpsBase'de:** Burada E0'dan E8'e, etiket olarak taşınıyor.

### In progress
**TR:** In progress (devam ediyor)

Someone is working on it right now. Move it here before the first commit, not after.

Şu anda birisi üzerinde çalışıyor. Buraya ilk commit'ten sonra değil, önce taşınır.

### In review
**TR:** In review (incelemede)

The work is done but one criterion cannot be verified yet — it needs a credential, a decision, or something only a human can do. The reason goes in a comment.

İş bitti ama bir kriter henüz doğrulanamıyor — bir kimlik bilgisi, bir karar ya da yalnızca insanın yapabileceği bir şey gerekiyor. Sebep yoruma yazılır.

> **In XenOpsBase:** Not a waiting room for finished work. If everything is verified, it is Done.  
> **XenOpsBase'de:** Bitmiş işin bekleme odası değildir. Her şey doğrulandıysa Done'dır.

### Issue
**TR:** Issue (iş kaydı)

One unit of tracked work, with a scope and acceptance criteria.

Kapsamı ve kabul kriterleri olan, takip edilen tek iş birimi.

### Kanban board
**TR:** Kanban panosu

Work as cards moving left to right through columns. The board's whole purpose is to show what is actually being worked on right now.

İşin, sütunlar arasında soldan sağa hareket eden kartlar olarak görünmesi. Panonun tüm amacı, şu anda gerçekten neyin yapıldığını göstermektir.

> **In XenOpsBase:** github.com/users/mertkan-iscan/projects/5  
> **XenOpsBase'de:** github.com/users/mertkan-iscan/projects/5

### Label
**TR:** Label (etiket)

A tag on an issue used for filtering — the epic, or a type like adr or bug.

Filtreleme için issue'ya takılan etiket — epic ya da adr, bug gibi bir tür.

### Milestone
**TR:** Milestone (kilometre taşı)

GitHub's grouping with a shared goal and optional due date. Used here to mirror the epics.

GitHub'ın ortak hedefli ve isteğe bağlı tarihli gruplaması. Burada epic'leri yansıtmak için kullanılıyor.

### Priority (P0 / P1 / P2)
**TR:** Öncelik (P0 / P1 / P2)

P0 blocks the critical path — nothing important ships without it. P1 is needed but not blocking. P2 is wanted.

P0 kritik yolu tıkar — o olmadan önemli hiçbir şey çıkmaz. P1 gerekli ama tıkayıcı değil. P2 ise istenen.

### Pull request (PR)
**TR:** Pull request (PR)

A proposed change, reviewed and checked before it joins main.

main'e katılmadan önce incelenen ve kontrol edilen değişiklik önerisi.

> **In XenOpsBase:** One task per PR. Link with Closes #N. The body says what changed, why, and how it was verified.  
> **XenOpsBase'de:** PR başına bir görev. Closes #N ile bağla. Gövde neyin değiştiğini, neden ve nasıl doğrulandığını anlatır.

### Ready
**TR:** Ready (hazır)

Unblocked and specified well enough to begin without asking anything first.

Önü açık ve hiçbir şey sormadan başlanabilecek kadar net tanımlanmış.

### Runbook
**TR:** Runbook (işletme kılavuzu)

The operational how-to for one area: what to run, what to check, what to do when it breaks.

Tek bir alan için işletme rehberi: ne çalıştırılır, ne kontrol edilir, bozulunca ne yapılır.

> **In XenOpsBase:** docs/runbooks/  
> **XenOpsBase'de:** docs/runbooks/

### Semantic versioning
**TR:** Anlamsal sürümleme (semver)

MAJOR.MINOR.PATCH — major breaks, minor adds, patch fixes.

ANA.YAN.YAMA — ana sürüm kırar, yan sürüm ekler, yama düzeltir.

### Size (S / M / L / XL)
**TR:** Boyut (S / M / L / XL)

A rough effort estimate, not hours. Its job is to flag the XL card that should probably be split.

Kaba efor tahmini, saat değil. Asıl işi, muhtemelen bölünmesi gereken XL kartı işaretlemektir.

### Spike
**TR:** Spike

A timeboxed investigation whose output is a written answer, not shipped code.

Çıktısı gönderilmiş kod değil yazılı bir cevap olan, süresi sınırlı araştırma.

> **In XenOpsBase:** docs/spikes/t-3.1-jhipster.md  
> **XenOpsBase'de:** docs/spikes/t-3.1-jhipster.md

### Squash merge
**TR:** Squash merge

Collapsing every commit on the branch into one commit on main. The PR title becomes that commit message — which is why the title is what gets linted.

Daldaki tüm commit'leri main üzerinde tek commit'e indirmek. PR başlığı o commit mesajı olur — başlığın linter'dan geçmesinin sebebi budur.

### Task ID (T-x.y)
**TR:** Görev kimliği (T-x.y)

The stable identifier for a task: T-2.4 is epic 2, task 4. It appears in the issue title, the branch name and the commit.

Görevin sabit kimliği: T-2.4, epic 2'nin 4. görevi. Issue başlığında, dal adında ve commit'te geçer.

### WIP limit
**TR:** WIP limiti

A cap on how many cards may sit in one column. Finishing beats starting.

Bir sütunda aynı anda kaç kart durabileceğinin sınırı. Bitirmek, başlamaktan önemlidir.


<a id="proj"></a>

## Bu projeye özel / Specific to this project

### Cold rebuild
**TR:** Sıfırdan yeniden kurulum

Going from nothing at all to a fully working stack, automated and timed. Here it is the everyday path, not a rare fire drill.

Hiç yoktan tam çalışan bir yığına, otomatik ve süresi ölçülerek gitmek. Burada bu, nadir bir yangın tatbikatı değil, günlük yol.

> **In XenOpsBase:** T-7.2, the last link in the critical path. The DR test and the deploy pipeline are the same code.  
> **XenOpsBase'de:** T-7.2, kritik yolun son halkası. Felaket kurtarma testi ile dağıtım hattı aynı koddur.

### Core service
**TR:** Core servisi

The back deployable: Spring Boot on Postgres, a resource server with no domain entities yet. Where your business logic will eventually live.

Arkadaki dağıtılabilir parça: Postgres üzerinde Spring Boot, henüz alan varlığı olmayan bir resource server. İş mantığın sonunda buraya gelecek.

> **In XenOpsBase:** services/core  
> **XenOpsBase'de:** services/core

### E0 — Foundations & decisions
**TR:** E0 — Temeller ve kararlar

Repo governance and the ADRs everything else depends on. Complete except T-0.6.

Depo yönetişimi ve diğer her şeyin dayandığı ADR'ler. T-0.6 hariç tamamlandı.

### E1 — Infrastructure as code
**TR:** E1 — Kod olarak altyapı

Terraform: state, buckets, the cluster itself, environments, network hardening, CI.

Terraform: state, bucket'lar, kümenin kendisi, ortamlar, ağ sıkılaştırma, CI.

### E2 — Cluster platform
**TR:** E2 — Küme platformu

The off-the-shelf layer installed by GitOps: ingress, certificates, secrets, Postgres, Keycloak, observability, autoscaling.

GitOps'un kurduğu hazır katman: ingress, sertifikalar, sırlar, Postgres, Keycloak, gözlemlenebilirlik, otomatik ölçekleme.

### E3 — Application skeleton
**TR:** E3 — Uygulama iskeleti

The two services, their auth model, database migrations, document storage and cross-cutting HTTP behaviour.

İki servis, kimlik modeli, veritabanı göçleri, doküman saklama ve kesişen HTTP davranışları.

### E4 — Developer experience
**TR:** E4 — Geliştirici deneyimi

Everything about the loop a contributor lives in: local startup time, test harness, code style, docs.

Katkıcının içinde yaşadığı döngüye dair her şey: yerel başlatma süresi, test altyapısı, kod stili, dokümanlar.

### E5 — Testing strategy
**TR:** E5 — Test stratejisi

What gets tested at which level, and the gates that enforce it.

Neyin hangi seviyede test edileceği ve bunu zorunlu kılan kapılar.

### E6 — CI/CD
**TR:** E6 — CI/CD

Building images, securing the supply chain, promoting between environments, and rolling back.

İmaj üretmek, tedarik zincirini güvenceye almak, ortamlar arası yükseltmek ve geri almak.

### E7 — Disaster recovery & operations
**TR:** E7 — Felaket kurtarma ve işletme

Proving the system can come back: RPO/RTO, cold rebuild, restore drills, PITR, offsite copies, alerting.

Sistemin geri gelebildiğini kanıtlamak: RPO/RTO, sıfırdan kurulum, geri yükleme tatbikatları, PITR, farklı konumda kopya, alarm.

### E8 — Security, cost & release
**TR:** E8 — Güvenlik, maliyet ve sürüm

Threat model, hardening, rate limiting, cost guardrails, and finally tagging v1.0.0 by forking it into a throwaway project.

Tehdit modeli, sıkılaştırma, hız sınırlama, maliyet korkulukları ve nihayet tek kullanımlık bir projeye fork'layarak v1.0.0 etiketlemek.

### Gateway
**TR:** Gateway

The front deployable: handles the OIDC login, terminates the session, and relays tokens to the core service. Spring Cloud Gateway on WebFlux.

Öndeki dağıtılabilir parça: OIDC girişini yürütür, oturumu sonlandırır ve token'ları core servise iletir. WebFlux üzerinde Spring Cloud Gateway.

> **In XenOpsBase:** services/gateway  
> **XenOpsBase'de:** services/gateway

### hedportal-terraform
**TR:** hedportal-terraform

The prior project this one generalises from. The stemcell exists partly to close the three gaps its DR doc admits: no offsite copy, no schema rollback, no PITR.

Bu projenin genellendiği önceki proje. Stemcell kısmen onun felaket kurtarma belgesinin itiraf ettiği üç boşluğu kapatmak için var: farklı konumda kopya yok, şema geri alma yok, PITR yok.

### infra/terraform/cluster
**TR:** infra/terraform/cluster

The ephemeral root module. Builds the K3s cluster and bootstraps Argo CD. Everything it owns is disposable.

Geçici kök modül. K3s kümesini kurar ve Argo CD'yi başlatır. Sahip olduğu her şey atılabilirdir.

### infra/terraform/edge
**TR:** infra/terraform/edge

The Cloudflare root module: DNS records and the tunnel. Survives cluster rebuilds, which is why the hostnames stay stable.

Cloudflare kök modülü: DNS kayıtları ve tünel. Küme yeniden kurulsa da yaşar; alan adlarının sabit kalmasının sebebi bu.

### infra/terraform/storage
**TR:** infra/terraform/storage

The durable root module. Owns the buckets holding documents, database backups and Loki chunks. Deliberately out of reach of the cluster module's destroy.

Kalıcı kök modül. Dokümanları, veritabanı yedeklerini ve Loki chunk'larını tutan bucket'ların sahibi. Cluster modülünün destroy'unun bilinçli olarak erişemeyeceği yerde.

### make up / make down
**TR:** make up / make down

The intended one-command cluster lifecycle: build the whole thing, tear the whole thing down.

Hedeflenen tek komutluk küme yaşam döngüsü: her şeyi kur, her şeyi yık.

> **In XenOpsBase:** T-1.7, still in the backlog — today it is the separate cluster-apply and cluster-destroy targets.  
> **XenOpsBase'de:** T-1.7, hâlâ backlog'da — bugün ayrı ayrı cluster-apply ve cluster-destroy hedefleri var.

### Near zero when idle
**TR:** Boştayken sıfıra yakın

Not a budget figure — the architectural constraint that produces everything else. If the cluster must be destroyable at any moment, nothing important can live in it.

Bir bütçe rakamı değil — diğer her şeyi doğuran mimari kısıt. Küme her an yok edilebilir olmak zorundaysa, içinde önemli hiçbir şey yaşayamaz.

### platform/components
**TR:** platform/components

Shared building blocks referenced by the environment overlays, so dev, staging and prod do not each redefine the same operator.

Ortam katmanlarının başvurduğu ortak yapı taşları; böylece dev, staging ve prod aynı operatörü ayrı ayrı tanımlamaz.

### platform/envs
**TR:** platform/envs

The GitOps tree. Everything Argo CD installs into the cluster is a Kustomize overlay under here, one folder per environment.

GitOps ağacı. Argo CD'nin kümeye kurduğu her şey burada, ortam başına bir klasörde, Kustomize katmanı olarak duruyor.

### Stemcell
**TR:** Stemcell (kök hücre)

The name of this repo, and the metaphor behind it: an undifferentiated backend that can become any project. Production-shaped, with no business logic in it.

Bu deponun adı ve arkasındaki metafor: henüz farklılaşmamış, her projeye dönüşebilen bir arka uç. Üretim biçiminde ama içinde hiç iş mantığı yok.

> **In XenOpsBase:** You fork it per project and grow domain code on top; you do not add features to the stemcell itself.  
> **XenOpsBase'de:** Proje başına fork'lar ve üstüne alan kodunu büyütürsün; stemcell'in kendisine özellik eklemezsin.

### The durable-state boundary
**TR:** Kalıcı durum sınırı

The single hardest line in the design: what may live outside the cluster and survive, versus what is inside and disposable. Everything else follows from it.

Tasarımdaki en katı çizgi: kümenin dışında yaşayıp hayatta kalabilecekler ile içeride olup atılabilirler. Diğer her şey bundan türüyor.

> **In XenOpsBase:** ADR-0002, and the two-column table in the README.  
> **XenOpsBase'de:** ADR-0002 ve README'deki iki sütunlu tablo.

### The no-manual-configuration rule
**TR:** Elle yapılandırma yasağı

No kubectl apply against a live cluster, no click in the Hetzner console, no realm edited in the Keycloak admin UI. If you cannot express it as code in this repo, that is the bug.

Canlı kümeye kubectl apply yok, Hetzner panelinde tıklama yok, Keycloak arayüzünde realm düzenleme yok. Bunu bu repoda kod olarak ifade edemiyorsan, asıl hata odur.

### XenOpsBase
**TR:** XenOpsBase

The project name. Java package root com.xenopsoftware.core.

Projenin adı. Java paket kökü com.xenopsoftware.core.


<a id="pano"></a>

## Pano kartları / Board items

Panonun beş sütunu: **Backlog** (başlamamış) → **Ready** (hazır) → **In progress** (devam ediyor) → **In review** (incelemede) → **Done** (bitti). Her görev beş sütunun hepsinden geçer.


### E0 — Temeller & kararlar / Foundations & decisions

#### T-0.1 — Repo hygiene: README, LICENSE, CODEOWNERS, branch protection
`Done` · `P0` · `S` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/2)

Set up the ground rules of the repository so every later change has to come through the same gate: a licence, a CODEOWNERS file, a protected main branch, commit-message linting and issue templates.

Deponun temel kurallarını kur ki sonraki her değişiklik aynı kapıdan geçmek zorunda kalsın: lisans, CODEOWNERS dosyası, korumalı main dalı, commit mesajı denetimi ve issue şablonları.

#### T-0.2 — Adopt ADR process; ADR-001 gateway plus core service topology
`Done` · `P0` · `S` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/3)

Decide where architecture decisions get written down, then write the first one: why an API gateway plus one core service, instead of a monolith or five microservices.

Mimari kararların nereye yazılacağına karar ver, sonra ilkini yaz: neden monolit ya da beş mikroservis değil de bir API gateway ve tek bir core servis.

#### T-0.3 — ADR-002: ephemeral cluster and the durable-state boundary
`Done` · `P0` · `M` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/4)

The decision the whole project rests on: draw the line between what lives outside the cluster and survives a full destroy, and what lives inside and is disposable.

Tüm projenin dayandığı karar: kümenin dışında yaşayıp tam bir silmeden sağ çıkanlarla, içeride yaşayıp atılabilir olanlar arasındaki çizgiyi çiz.

#### T-0.4 — ADR-003: secrets management, External Secrets vs SOPS vs Vault
`Done` · `P0` · `M` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/5)

Choose how secrets are stored. Compared External Secrets, SOPS and Vault; picked SOPS with age, meaning secrets sit encrypted in git with exactly one key you have to supply by hand.

Sırların nasıl saklanacağını seç. External Secrets, SOPS ve Vault karşılaştırıldı; age ile SOPS seçildi — yani sırlar git'te şifreli durur ve elle vermen gereken tek bir anahtar vardır.

#### T-0.5 — ADR-004: GitOps engine, Argo CD vs Flux
`Done` · `P0` · `S` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/6)

Choose the GitOps engine. Argo CD over Flux, with the reasoning recorded so nobody relitigates it later.

GitOps motorunu seç. Flux yerine Argo CD, gerekçesi kayıt altına alınarak — böylece kimse ileride bu tartışmayı yeniden açmaz.

#### T-0.6 — ADR-0005: add the OS snapshot to the durable-state table
`Backlog` · `P1` · `S` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/69)

Follow-up: the OS snapshot nodes boot from is durable state too. Without it a cold rebuild has an extra manual step, so it belongs in the durable-state table.

Takip işi: node'ların açıldığı OS snapshot'ı da kalıcı durumdur. O olmadan sıfırdan kurulumda fazladan elle bir adım gerekir, dolayısıyla kalıcı durum tablosuna aittir.


### E1 — Altyapı (Terraform) / Infrastructure as code

#### T-1.1 — Terraform remote state on Hetzner Object Storage, with locking
`Done` · `P0` · `M` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/7)

Give Terraform a shared home for its state file, with locking so two applies can never run at once. This is the first thing that has to exist before any infrastructure can be built.

Terraform'un state dosyası için ortak bir ev ver, iki apply'ın aynı anda çalışamaması için kilitle. Herhangi bir altyapı kurulmadan önce var olması gereken ilk şey budur.

#### T-1.2 — Object storage buckets, versioning and lifecycle rules
`Done` · `P0` · `M` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/8)

Create the buckets that hold the things that must never be lost — documents, database backups, log chunks — with versioning on and lifecycle rules to stop them growing forever.

Asla kaybedilmemesi gereken şeyleri tutan bucket'ları yarat — dokümanlar, veritabanı yedekleri, log parçaları — versiyonlama açık ve sonsuza kadar büyümesinler diye yaşam döngüsü kurallarıyla.

#### T-1.3 — kube-hetzner baseline: K3s cluster, node pools, CNI, CSI and CCM
`Done` · `P0` · `L` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/9)

Build the actual Kubernetes cluster with the kube-hetzner module: nodes, networking plugin, storage driver and the cloud controller that ties Kubernetes to Hetzner.

kube-hetzner modülüyle asıl Kubernetes kümesini kur: node'lar, ağ eklentisi, depolama sürücüsü ve Kubernetes'i Hetzner'a bağlayan bulut denetleyicisi.

#### T-1.4 — Environment layout for dev, staging and prod
`Done` · `P0` · `M` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/10)

Make dev, staging and prod three real, separated environments — separate variables, separate state, separate buckets — driven by an ENV switch rather than by editing files.

dev, staging ve prod'u gerçekten ayrı üç ortam yap — ayrı değişkenler, ayrı state, ayrı bucket'lar — dosya düzenleyerek değil bir ENV anahtarıyla yönetilsin.

#### T-1.5 — Network and firewall hardening
`In review` · `P0` · `M` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/11)

Close everything that does not need to be open: firewall rules, SSH policy, and a script that probes every public address and proves only the intended ports answer.

Açık olması gerekmeyen her şeyi kapat: güvenlik duvarı kuralları, SSH politikası ve her genel adresi yoklayıp yalnızca istenen portların yanıt verdiğini kanıtlayan bir betik.

#### T-1.6 — Cloudflare Terraform: DNS, proxy, TLS mode and WAF
`In review` · `P1` · `M` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/12)

Manage the Cloudflare side as code too: DNS records, whether traffic is proxied, the TLS mode and the firewall rules at the edge.

Cloudflare tarafını da kod olarak yönet: DNS kayıtları, trafiğin vekil üzerinden geçip geçmeyeceği, TLS modu ve kenardaki güvenlik duvarı kuralları.

#### T-1.7 — make up and make down: one-command cluster lifecycle
`Backlog` · `P0` · `M` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/13)

Reduce the whole cluster lifecycle to two commands. Right now it takes several ordered make targets; the goal is make up and make down.

Tüm küme yaşam döngüsünü iki komuta indir. Şu an sıralı birkaç make hedefi gerekiyor; hedef make up ve make down.

#### T-1.8 — Terraform CI: fmt, validate, tflint, checkov, plan on PR
`Done` · `P1` · `M` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/14)

Run formatting, validation, linting and a security scan on every infrastructure pull request, and post the plan as a comment so changes are reviewed before they are applied.

Her altyapı pull request'inde biçimlendirme, doğrulama, lint ve güvenlik taraması çalıştır; plan'ı yorum olarak yaz ki değişiklikler uygulanmadan önce incelensin.

#### T-1.9 — scheduled Terraform state backup into the versioned Hetzner bucket
`Backlog` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/71)

Back up the Terraform state file itself on a schedule into the versioned bucket. State is the map of everything that exists; losing it is worse than losing the cluster.

Terraform state dosyasının kendisini düzenli olarak versiyonlu bucket'a yedekle. State, var olan her şeyin haritasıdır; onu kaybetmek kümeyi kaybetmekten kötüdür.

#### T-1.10 — Tailscale node transport breaks the Hetzner CCM; close the public API endpoint
`Done` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/84)

Bug: moving node traffic onto Tailscale stopped the Hetzner cloud controller from recognising nodes. Fixed by adjusting the transport and closing the public API endpoint entirely.

Hata: node trafiğini Tailscale'e taşımak, Hetzner bulut denetleyicisinin node'ları tanımasını engelledi. Taşıma katmanı düzeltilerek ve genel API ucu tamamen kapatılarak çözüldü.

#### T-1.11 — cluster-destroy orphans CSI volumes that bill forever
`Done` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/109)

Bug with a bill attached: destroying the cluster left Hetzner volumes behind that nobody owned and that kept charging. Fixed with a release script and a teardown check.

Faturası olan hata: kümeyi silmek, sahibi olmayan ve faturalanmaya devam eden Hetzner diskleri bıraktı. Bir serbest bırakma betiği ve yıkım kontrolüyle çözüldü.

#### T-1.12 — dev cluster is out of memory headroom; Argo repo-server is unstable
`Done` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/133)

Bug: the dev cluster had no memory headroom left, so the Argo CD component that renders manifests kept being killed and restarted.

Hata: dev kümesinde bellek payı kalmadı, bu yüzden manifest'leri işleyen Argo CD bileşeni sürekli öldürülüp yeniden başlatıldı.


### E2 — Küme platformu / Cluster platform

#### T-2.1 — GitOps bootstrap: bare cluster converges to full platform unattended
`Done` · `P0` · `L` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/15)

Make a bare cluster turn itself into the full platform with no further human input: Terraform installs Argo CD and one root app, and everything else follows from git.

Boş bir kümenin, başka hiçbir insan müdahalesi olmadan kendini tam platforma dönüştürmesini sağla: Terraform Argo CD'yi ve tek bir kök uygulamayı kurar, gerisi git'ten gelir.

#### T-2.2 — Ingress, cert-manager and Let us Encrypt via DNS-01
`Done` · `P0` · `M` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/16)

Get HTTPS working automatically: an ingress controller to route traffic and cert-manager to obtain and renew certificates via a DNS challenge, since nothing here is publicly reachable.

HTTPS'i otomatik çalıştır: trafiği yönlendiren bir ingress denetleyicisi ve DNS doğrulamasıyla sertifika alıp yenileyen cert-manager — çünkü buradaki hiçbir şeye dışarıdan erişilemiyor.

#### T-2.3 — External secrets wired to the chosen store
`Done` · `P0` · `M` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/17)

Wire the secrets mechanism into the cluster so encrypted values in git become usable Kubernetes Secrets at deploy time.

Sır mekanizmasını kümeye bağla ki git'teki şifreli değerler dağıtım anında kullanılabilir Kubernetes Secret'larına dönüşsün.

#### T-2.4 — CloudNativePG with WAL archiving to object storage
`Done` · `P0` · `L` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/18)

Run Postgres properly under an operator, and continuously ship its write-ahead log to object storage. This is what makes recovery to any point in time possible later.

Postgres'i bir operatör altında düzgün çalıştır ve write-ahead log'unu sürekli nesne depolamaya gönder. İleride herhangi bir ana geri dönüşü mümkün kılan şey budur.

#### T-2.5 — Keycloak with declarative realm import
`Done` · `P0` · `L` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/19)

Run Keycloak with its realm defined as a file in git and imported on startup, so users, roles and clients survive a rebuild without anyone touching the admin UI.

Keycloak'ı, realm'i git'te dosya olarak tanımlanmış ve açılışta içeri aktarılacak şekilde çalıştır; böylece kullanıcılar, roller ve client'lar kimse admin arayüzüne dokunmadan yeniden kurulumdan sağ çıkar.

#### T-2.6 — kube-prometheus-stack and Grafana with dashboards as code
`In review` · `P1` · `L` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/20)

Install the metrics stack and define the dashboards as files, so a rebuild brings the dashboards back instead of leaving you to recreate them by clicking.

Metrik yığınını kur ve panoları dosya olarak tanımla; böylece yeniden kurulum panoları da geri getirir, tıklayarak yeniden yapmak zorunda kalmazsın.

#### T-2.7 — Loki, Tempo and the OpenTelemetry Collector
`In progress` · `P1` · `L` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/21)

Add the other two thirds of observability: log storage, trace storage, and the collector that receives telemetry from the services and forwards it.

Gözlemlenebilirliğin diğer üçte ikisini ekle: log deposu, iz deposu ve servislerden telemetriyi alıp ileten toplayıcı.

#### T-2.8 — Autoscaling: cluster-autoscaler, HPAs and a resource policy
`Backlog` · `P1` · `M` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/22)

Let the system grow and shrink on its own: pod-level autoscaling, node-level autoscaling, and a written policy for how much CPU and memory each workload may ask for.

Sistemin kendi kendine büyüyüp küçülmesini sağla: pod seviyesinde ve node seviyesinde otomatik ölçekleme, ayrıca her iş yükünün ne kadar CPU ve bellek isteyebileceğine dair yazılı bir politika.

#### T-2.9 — Velero backup of cluster resources
`Backlog` · `P2` · `M` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/23)

Back up the cluster's own objects to object storage. Low priority on purpose — in a GitOps repo git is already the backup of every manifest.

Kümenin kendi nesnelerini nesne depolamaya yedekle. Bilinçli olarak düşük öncelikli — GitOps deposunda git zaten her manifest'in yedeğidir.

#### T-2.10 — after a rebuild the database is empty AND archiving is refused, while reporting Healthy
`Ready` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/113)

The dangerous one: after a rebuild the database came up empty and refused to archive, while still reporting itself Healthy. A green status that is lying is worse than a red one.

Tehlikeli olan: yeniden kurulumdan sonra veritabanı boş açıldı ve arşivlemeyi reddetti, ama kendini hâlâ Healthy raporluyordu. Yalan söyleyen yeşil bir durum, kırmızıdan kötüdür.

#### T-2.11 — in-memory data store (Redis or Valkey) for cache, rate limiting and locks
`Backlog` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/127)

Add an in-memory store for caching, rate-limit counters and distributed locks — the piece almost every real project ends up needing.

Önbellek, hız sınırı sayaçları ve dağıtık kilitler için bellek içi bir depo ekle — neredeyse her gerçek projenin sonunda ihtiyaç duyduğu parça.


### E3 — Uygulama iskeleti / Application skeleton

#### T-3.1 — JHipster spike: JDL for gateway plus core service
`Done` · `P0` · `M` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/24)

Investigate JHipster before committing to it: what it actually generates, what will have to be deleted, and what it costs to leave later. Output was a written spike, not code.

JHipster'a bağlanmadan önce araştır: gerçekte ne üretiyor, neyin silinmesi gerekecek ve sonradan ondan ayrılmanın bedeli ne. Çıktı kod değil, yazılı bir spike oldu.

#### T-3.2 — Gateway: Spring Cloud Gateway with OIDC against Keycloak
`Done` · `P0` · `L` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/25)

Build the front service: it logs the user in against Keycloak, holds the session, and passes the identity onward to the core service.

Ön servisi kur: kullanıcıyı Keycloak'a karşı giriş yaptırır, oturumu tutar ve kimliği core servise iletir.

#### T-3.3 — Core service: Spring Boot on Postgres, with no domain entities
`In review` · `P0` · `M` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/26)

Build the back service on Postgres with deliberately no business entities — only the plumbing every future project will need.

Arka servisi Postgres üzerinde, bilinçli olarak hiç iş varlığı olmadan kur — yalnızca her gelecek projenin ihtiyaç duyacağı tesisat.

#### T-3.4 — Detach from the generator
`Backlog` · `P0` · `L` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/27)

Remove the generator's markers and machinery so the code is simply yours and no future regeneration can overwrite it.

Jeneratörün işaretlerini ve makinesini kaldır ki kod sadece sana ait olsun ve ileride yeniden üretim onu ezemesin.

#### T-3.5 — Auth model: OIDC flow, token relay, roles, service-to-service
`Backlog` · `P0` · `L` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/28)

Write down and implement the full auth model: the browser login flow, how the token gets to the core service, how roles are checked, and how two backends prove who they are to each other.

Kimlik modelinin tamamını yaz ve uygula: tarayıcı giriş akışı, token'ın core servise nasıl ulaştığı, rollerin nasıl kontrol edildiği ve iki arka ucun birbirine kim olduğunu nasıl kanıtladığı.

#### T-3.6 — Flyway baseline with ddl-auto set to validate from commit one
`Backlog` · `P0` · `M` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/29)

Make the database schema managed only by numbered migration files, and configure the app to verify the schema at startup rather than silently changing it.

Veritabanı şemasını yalnızca numaralı migration dosyalarıyla yönetilir hale getir ve uygulamayı, şemayı sessizce değiştirmek yerine açılışta doğrulayacak şekilde ayarla.

#### T-3.7 — Document storage module over the S3 API
`Backlog` · `P0` · `L` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/30)

Build file upload and download against the plain S3 API only, so document storage can move between providers without a rewrite.

Dosya yükleme ve indirmeyi yalnızca düz S3 API üzerine kur; böylece doküman saklama, yeniden yazmadan sağlayıcı değiştirebilsin.

#### T-3.8 — Cross-cutting HTTP contract
`Backlog` · `P1` · `L` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/31)

Decide once, for every endpoint: what an error looks like, how pagination and filtering work, which headers carry the request ID, which status codes mean what.

Her uç nokta için bir kez karar ver: hata neye benzer, sayfalama ve filtreleme nasıl çalışır, hangi başlık istek kimliğini taşır, hangi durum kodu ne demektir.

#### T-3.9 — Resilience: timeouts, retries, circuit breakers, bulkheads
`Backlog` · `P1` · `M` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/32)

Make calls between services fail safely: every call gets a timeout, retries are bounded, a sick dependency gets cut off, and one slow backend cannot consume all the threads.

Servisler arası çağrıların güvenli şekilde başarısız olmasını sağla: her çağrının zaman aşımı olsun, yeniden denemeler sınırlı olsun, hasta bağımlılık devre dışı bırakılsın ve yavaş bir arka uç tüm thread'leri yutamasın.

#### T-3.10 — Extension seams: audit, soft delete, tenancy, outbox
`Backlog` · `P1` · `L` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/33)

Leave the hooks a real project will need — audit fields, soft delete, tenant scoping, the outbox — in place from the start, because retrofitting any of them later is painful.

Gerçek bir projenin ihtiyaç duyacağı kancaları baştan bırak — denetim alanları, yumuşak silme, kiracı kapsamı, outbox — çünkü bunları sonradan eklemek acı verici.

#### T-3.11 — OpenAPI via springdoc, plus generated clients
`Backlog` · `P2` · `M` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/34)

Generate the API description from the code, publish it, and generate typed clients from it so callers do not hand-write request code.

API tanımını koddan üret, yayımla ve ondan tipli istemciler üret ki çağıranlar istek kodunu elle yazmasın.

#### T-3.12 — gateway throws NullPointerException when a token has no preferred_username
`Done` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/140)

Bug: the gateway crashed when a token arrived without the preferred_username claim. The real lesson is that optional claims must be treated as optional.

Hata: token preferred_username claim'i olmadan gelince gateway çöktü. Asıl ders, isteğe bağlı claim'lerin isteğe bağlı olarak ele alınması gerektiği.


### E4 — Geliştirici deneyimi / Developer experience

#### T-4.1 — Local inner loop, under five minutes from clone
`Backlog` · `P0` · `L` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/35)

Make it possible to go from a fresh clone to a running system on your own machine in under five minutes, because every second here is paid many times a day.

Yeni bir klondan kendi makinende çalışan bir sisteme beş dakikanın altında geçilebilsin, çünkü buradaki her saniyenin bedeli günde defalarca ödeniyor.

#### T-4.2 — Testcontainers harness for Postgres, Keycloak and S3
`Backlog` · `P0` · `M` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/36)

Give tests real dependencies instead of mocks: a throwaway Postgres, Keycloak and S3 started automatically for the duration of the test run.

Testlere sahte nesneler yerine gerçek bağımlılıklar ver: test süresince otomatik başlatılan tek kullanımlık Postgres, Keycloak ve S3.

#### T-4.3 — Code style and pre-commit hygiene
`Backlog` · `P1` · `S` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/37)

Automate formatting and style so code review is about design, not about spacing, and so nothing unformatted can reach main.

Biçimlendirmeyi ve stili otomatikleştir ki kod incelemesi boşluk değil tasarım hakkında olsun ve biçimlenmemiş hiçbir şey main'e ulaşamasın.

#### T-4.4 — Devcontainer
`Backlog` · `P2` · `M` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/38)

Define the development environment itself as a container, so a new contributor gets identical tooling without installing anything.

Geliştirme ortamının kendisini konteyner olarak tanımla; yeni bir katkıcı hiçbir şey kurmadan aynı araçlara sahip olsun.

#### T-4.5 — Docs: ADRs, runbooks and the start-a-new-project guide
`Backlog` · `P1` · `M` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/39)

Write the documentation a fork actually needs: the decisions, the runbooks, and a guide for starting a new project from this one.

Bir fork'un gerçekten ihtiyaç duyduğu dokümanları yaz: kararlar, runbook'lar ve buradan yeni bir projeye başlama rehberi.


### E5 — Test stratejisi / Testing strategy

#### T-5.1 — Test strategy document
`Backlog` · `P0` · `M` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/40)

Write down what gets tested at which level and why, so test decisions are not made case by case forever.

Neyin hangi seviyede ve neden test edileceğini yaz ki test kararları sonsuza kadar duruma göre verilmesin.

#### T-5.2 — Unit and slice test baseline with a coverage gate
`Backlog` · `P0` · `M` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/41)

Establish the baseline of fast tests and a coverage threshold the build enforces.

Hızlı testlerin temelini ve derlemenin zorunlu kıldığı bir kapsam eşiğini oluştur.

#### T-5.3 — Integration tests against real dependencies
`Backlog` · `P0` · `L` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/42)

Test against real Postgres, Keycloak and S3 rather than mocks, so the tests catch integration problems mocks cannot.

Sahte nesneler yerine gerçek Postgres, Keycloak ve S3'e karşı test et; böylece testler sahtelerin yakalayamayacağı entegrasyon sorunlarını yakalar.

#### T-5.4 — Contract tests between gateway and core service
`Backlog` · `P1` · `L` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/43)

Pin down the agreement between gateway and core so one side cannot break the other silently.

Gateway ile core arasındaki anlaşmayı sabitle ki bir taraf diğerini sessizce bozamasın.

#### T-5.5 — End-to-end smoke suite against a fresh cluster
`Backlog` · `P1` · `L` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/44)

Run a small suite against a freshly built cluster to prove the whole thing actually works end to end after a rebuild.

Yeni kurulmuş bir kümeye karşı küçük bir takım çalıştır; yeniden kurulumdan sonra her şeyin uçtan uca gerçekten çalıştığını kanıtla.

#### T-5.6 — Load baseline with k6 and published SLOs
`Backlog` · `P1` · `L` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/45)

Measure what the system does under load, then publish the availability and latency targets that measurement justifies.

Sistemin yük altında ne yaptığını ölç, sonra bu ölçümün gerekçelendirdiği erişilebilirlik ve gecikme hedeflerini yayımla.

#### T-5.7 — Chaos drills against the SLOs
`Backlog` · `P2` · `L` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/46)

Break things on purpose in a controlled way and check the system degrades within the targets you published.

Kontrollü şekilde bilerek bir şeyler boz ve sistemin yayımladığın hedeflerin içinde bozulup bozulmadığını kontrol et.

#### T-5.8 — Security testing in CI
`Backlog` · `P1` · `L` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/47)

Put dependency scanning, static analysis and container image scanning into the pipeline so vulnerabilities fail a build instead of being discovered later.

Bağımlılık taraması, statik analiz ve konteyner imaj taramasını hatta koy ki zafiyetler sonradan keşfedilmek yerine derlemeyi düşürsün.


### E6 — CI/CD / CI/CD

#### T-6.1 — Build pipeline: Maven, caching, Jib, GHCR
`Backlog` · `P0` · `M` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/48)

Build the two services reproducibly and push their images to the registry, with caching so the build stays fast.

İki servisi tekrarlanabilir şekilde derle ve imajlarını registry'ye gönder; derleme hızlı kalsın diye önbellekle.

#### T-6.2 — Supply chain: signing, provenance, verify on deploy
`Backlog` · `P2` · `L` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/49)

Sign the images, record how they were built, and refuse to deploy anything that fails that verification.

İmajları imzala, nasıl üretildiklerini kaydet ve bu doğrulamayı geçemeyen hiçbir şeyi dağıtma.

#### T-6.3 — GitOps promotion from dev to staging to prod
`Backlog` · `P0` · `L` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/50)

Move the same tested image from dev to staging to prod by changing a reference in git, never by rebuilding it for each environment.

Aynı test edilmiş imajı, her ortam için yeniden derleyerek değil git'te bir referans değiştirerek dev'den staging'e ve prod'a taşı.

#### T-6.4 — Rollback workflow, under five minutes
`Backlog` · `P0` · `M` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/51)

Make going back to the last known-good version a rehearsed, timed procedure rather than an improvisation during an incident.

Bilinen son çalışan sürüme dönmeyi, olay anında doğaçlama değil, prova edilmiş ve süresi ölçülmüş bir prosedür haline getir.

#### T-6.5 — Release automation and dependency updates
`Backlog` · `P1` · `M` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/52)

Automate version tagging, changelogs and dependency bumps so upgrades arrive continuously instead of as one large annual jump.

Sürüm etiketleme, değişiklik günlüğü ve bağımlılık güncellemelerini otomatikleştir ki yükseltmeler yılda bir büyük sıçrama yerine sürekli gelsin.


### E7 — Felaket kurtarma & işletme / Disaster recovery & operations

#### T-7.1 — DR plan with explicit RPO and RTO per component
`Backlog` · `P0` · `M` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/53)

For each component, write down how much data you can afford to lose and how long you can afford to be down. Numbers, not feelings.

Her bileşen için ne kadar veri kaybını ve ne kadar kesintiyi göze alabileceğini yaz. Hisler değil, sayılar.

#### T-7.2 — Cold rebuild: nothing to working stack, automated and measured
`Backlog` · `P0` · `XL` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/54)

The keystone task: prove that from nothing at all you can get to a fully working stack, automatically, and measure how long it takes.

Kilit taşı görev: hiç yoktan tam çalışan bir yığına otomatik olarak ulaşılabildiğini kanıtla ve ne kadar sürdüğünü ölç.

#### T-7.3 — Automated nightly restore drill
`Backlog` · `P1` · `L` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/55)

Restore from backup automatically every night and verify the result, because a backup you have never restored is only a hypothesis.

Her gece otomatik olarak yedekten geri yükle ve sonucu doğrula, çünkü hiç geri yüklemediğin yedek yalnızca bir varsayımdır.

#### T-7.4 — Prove point-in-time recovery
`Backlog` · `P0` · `L` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/56)

Prove you can restore the database to a chosen second, not just to last night's backup — the defence against a bad migration or a wrong delete.

Veritabanını dün geceki yedeğe değil, seçtiğin bir saniyeye geri getirebildiğini kanıtla — hatalı bir migration ya da yanlış bir silmeye karşı savunma budur.

#### T-7.5 — Offsite replication to a second provider
`Backlog` · `P1` · `M` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/57)

Copy the backups to a second provider, so losing the primary provider does not mean losing the data. One of the three gaps inherited from the prior project.

Yedekleri ikinci bir sağlayıcıya kopyala ki birincil sağlayıcıyı kaybetmek veriyi kaybetmek anlamına gelmesin. Önceki projeden devralınan üç boşluktan biri.

#### T-7.6 — Alerting, routing and postmortems
`Backlog` · `P1` · `M` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/58)

Decide which alerts exist, who they reach and how, and write the incident review process before the first incident, not during it.

Hangi alarmların olacağına, kime ve nasıl ulaşacağına karar ver; olay inceleme sürecini ilk olay sırasında değil, öncesinde yaz.

#### T-7.7 — automatic archive path isolation per cluster generation (prod-safe)
`Ready` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/122)

Give each rebuild of the cluster its own archive path, so a fresh cluster cannot write into the previous cluster's backup history and corrupt it. Especially important in production.

Kümenin her yeniden kurulumuna kendi arşiv yolunu ver ki yeni bir küme, öncekinin yedek geçmişine yazıp onu bozmasın. Özellikle üretimde kritik.


### E8 — Güvenlik, maliyet & sürüm / Security, cost & release

#### T-8.1 — Threat model over the stemcell
`Backlog` · `P1` · `L` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/59)

Write down who might attack this, through which door, and what you are deliberately choosing not to defend against.

Kimin, hangi kapıdan saldırabileceğini ve neye karşı bilinçli olarak savunma yapmamayı seçtiğini yaz.

#### T-8.2 — Cluster hardening
`Backlog` · `P1` · `L` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/60)

Tighten the cluster itself: pod security, network policies, non-root containers, restricted service accounts.

Kümenin kendisini sıkılaştır: pod güvenliği, ağ politikaları, root olmayan konteynerler, kısıtlı servis hesapları.

#### T-8.3 — Rate limiting and WAF
`Backlog` · `P1` · `M` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/61)

Cap how much traffic one caller can send and filter known attack patterns at the edge, before they reach the application.

Tek bir çağıranın gönderebileceği trafiği sınırla ve bilinen saldırı desenlerini uygulamaya ulaşmadan kenarda filtrele.

#### T-8.4 — Cost guardrails and auto-destroy
`Backlog` · `P1` · `M` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/62)

Put hard limits and an automatic teardown in place so a forgotten cluster cannot quietly run up a bill.

Katı sınırlar ve otomatik yıkım koy ki unutulmuş bir küme sessizce fatura biriktiremesin.

#### T-8.5 — Tag v1.0.0, validated by forking into a throwaway project
`Backlog` · `P1` · `L` · [issue](https://github.com/mertkan-iscan/xenopsbase-stemcell/issues/63)

Validate the whole stemcell by forking it into a disposable project and building something on it. If that works, tag version 1.0.0.

Tüm stemcell'i, tek kullanımlık bir projeye fork'layıp üzerine bir şey inşa ederek doğrula. Bu çalışıyorsa 1.0.0 sürümünü etiketle.

