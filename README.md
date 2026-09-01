# arcdesk (çalışma adı)

Base/Arbitrum ile Arc arasında USDC için non-custodial OTC takas masası. Maker'lar Arc'ta
süreli ilanlar açar, taker'lar kaynak zincirde öder, keeper ikisini eşleştirir. Fee %2,
taker öder. Kimse fonu emanetçi olarak tutmaz: her şey on-chain hashlock + timeout ile bağlı.

## Nasıl çalışıyor (HTLC akışı)

Sıra kasıtlı: **secret'i maker üretir**, çünkü Arc'ta gas parası USDC ve Arc'a ilk kez USDC
alan kullanıcının orada harcayacak parası yoktur. Bu yüzden taker'ın Arc'ta işlem yapması
hiçbir adımda gerekmez.

1. **Maker önce bağlanır** (Arc, `reserve`): keeper, maker'ın ilanından taker adına, maker'ın
   seçtiği hash ile ve alıcısı taker sabitlenmiş şekilde likidite ayırır. Uzun süreli.
2. **Taker sonra öder** (kaynak zincir, `lockPayment`): maker payı + %2 ücret aynı hash ile
   kilitlenir. Kısa süreli. Taker'ın tek işlemi budur.
3. **Maker ödemeyi alır** (`claimPayment`): secret'i kullanır ve böylece **secret zincirde
   herkese açılır**.
4. **Teslimat** (Arc, `claimReservation`): secret artık açık olduğu için bu çağrıyı herkes
   yapabilir, fonlar zaten taker'a sabitli. Keeper taker adına gönderir, taker gas ödemez.

Garanti: maker secret'i ancak ödeme kilitliyken açar; taker teslimat olmazsa süre dolunca
kendi parasını geri alır. Sıralamayı kontrat zorlar: bir ödeme en fazla `MAX_PAYMENT_WINDOW`
(30 dk) kilitli kalabilir, bir rezervasyon en az `MIN_RESERVATION_WINDOW` (90 dk) yaşar.
Yani secret açıldıktan sonra teslimat için her zaman geniş bir pencere kalır.

## Süreli ilanlar (masanın farkı)

Maker `postOffer(offerId, amount, premiumBps, expiry)` ile ilanı belli bir süreye kadar
açar (örn. 5-10 dk). Süre dolunca yeni rezervasyon alınmaz; `expireOffer` ile likidite
maker'a döner (herkes tetikleyebilir, maker uğraşmaz).

## Kontrat

Tek kontrat, iki zincire aynı bytecode ile deploy edilir: `contracts/src/ArcdeskEscrow.sol`.
Hangi bacağın kullanıldığını bulunduğu zincir belirler, ayar değil.

- **Likidite bacağı (Arc):** `postOffer` / `fundOffer` / `cancelOffer` / `expireOffer` /
  `reserve` / `claimReservation` / `refundReservation`
- **Ödeme bacağı (kaynak zincir):** `lockPayment` / `claimPayment` / `refundPayment`

Tek kontrat olmasının sebebi: incelenecek kod yüzeyi yarıya iner, iki deploy tek audit'e konu olur.

Güven modeli: taker tamamen trustless. Maker likiditesini keeper'a (operator) delege eder;
rezerve edilen fon yalnızca isimli taker'a veya refund'la maker'a döner, keeper kendine yönlendiremez.

## Test

```bash
cd contracts && forge test            # 29 test: happy path, refund, expiry, erişim, griefing
```

Uçtan uca (iki yerel zincir + keeper):

```bash
# iki anvil (kaynak + arc simülasyonu)
anvil --port 9987 & anvil --port 9988 &
cd keeper && npm install
SRC_URL=http://127.0.0.1:9987 ARC_URL=http://127.0.0.1:9988 node e2e.mjs
# -> "E2E PASS: full cross-chain swap settled through the keeper."
```

## Testnete deploy

```bash
cd contracts
# aynı kontrat, iki zincire
USDC=$SOURCE_USDC OPERATOR=$KEEPER_ADDR \
  forge script script/Deploy.s.sol --rpc-url $SOURCE_RPC --broadcast --private-key $PK
USDC=$ARC_USDC    OPERATOR=$KEEPER_ADDR \
  forge script script/Deploy.s.sol --rpc-url $ARC_RPC --broadcast --private-key $PK
```

Adresleri `.env`'e yaz, keeper'ı başlat: `cd keeper && node index.mjs`.

## Testnet dağıtımı (CANLI)

| Bacak | Zincir | Chain ID | Adres |
|---|---|---|---|
| Ödeme | Base Sepolia | 84532 | `0x309E0145Bda44081C2Cf4E196f5Eb21Da451ECd4` |
| Likidite | Arc testnet | 5042002 | `0x5a65Bc12Fb602c5CA0dfBdA422bb65bE6339B45f` |

USDC: Base Sepolia `0x036CbD53842c5426634e7929541eC2318f3dCF7e`, Arc `0x3600…0000` (6dp).
Deployer/operator: `0x7d2828dee9C6FE9253805314306Eda3fBded3465` (bu projeye özel, anahtar `.deployer.json`).
Testnet USDC: [faucet.circle.com](https://faucet.circle.com) → Arc Testnet.

Canlı doğrulama: `cd keeper && node live-e2e.mjs` → **LIVE E2E PASS**, gerçek çapraz zincir
takas (ilan → ödeme kilidi → keeper rezervasyonu → secret ile çekim → maker ödemesi + %2 ücret).

## Arc'a özgü teknik notlar

- Arc'ta USDC hem gas hem ERC20: `balanceOf` aslında **native bakiyenin 1e12'ye bölünmüş** hali (6dp görünüm, 18dp iç değer).
- Transferler zincir precompile'larına delege ediliyor: `0x1800…0000` (bakiye) ve `0x1800…0001` (`isBlocklisted`). **Arc'ta blocklist var**, escrow adresi de blocklist'e girebilir, mainnet öncesi düşünülmeli.
- Bu precompile'lar forge'da olmadığı için Arc tarafı fork'ta tam simüle edilemez, canlı zincirde doğrulanır.
- Public RPC'ler `eth_newFilter` desteklemiyor; keeper bu yüzden **getLogs poll** ile çalışıyor.

## Durum

- [x] Tek escrow kontratı (iki zincir aynı bytecode, HTLC, süreli + süresiz ilan)
- [x] 40 test (birim+fork+saldırı) (25 birim + 4 fork) + yerel iki zincirli e2e (PASS)
- [x] Testnet deploy: Base Sepolia + Arc testnet
- [x] Canlı çapraz zincir takas testi (PASS)
- [x] **A: secret'i maker üretir**, taker Arc'ta hiç işlem yapmaz (canlı doğrulandı)
- [x] Order backend (`backend/server.mjs`): API + ilan indexer + keeper tek süreç, SQLite, port 8899; canlı akış doğrulandı (quoted→reserved→paid→maker_paid→delivered)
- [x] Çok sayfalı frontend (`web/`): Trade / Post offer / Orders / Profile / How it works; backend aynı porttan sunuyor, cüzdan (window.ethereum) ile gerçek alım + refund butonu
- [ ] Maker API (üçüncü taraf maker'lar kendi hashlock'unu getirir; şimdilik tek maker = masa)
- [ ] VPS'e taşıma (backend + keeper 7/24)
- [ ] Bağımsız audit (mainnet öncesi ŞART)

## Çalıştırma

```bash
cd backend && PORT=8899 node server.mjs   # API + indexer + keeper + site: http://localhost:8899
```

## Güvenlik incelemesi (saldırgan testi)

40 test (birim + fork + saldırı). Bulundu ve DÜZELTİLDİ: (1) order-id front-run DoS -> ödeme
(orderId,payer) ile anahtarlandı; (2) keeper her hashlock-eşleşen ödemeyi tahsil ediyordu ->
sadece tam teklif edilen ödemeyi tahsil ediyor; (3) kimliksiz POST /orders bedava rezervasyon
-> per-offer cap(3) + IP rate-limit + otomatik iade sweeper; (4) SQLite hata sızıntısı -> katı
girdi doğrulama. BİLİNEN (design): operator maker ilanını boşaltabilir -> çözüm EIP-712 maker
imzası (mainnet öncesi 3. taraf maker için şart); şu an tek maker masa, 3. taraf fonu yok.

Not: kontratlar audit edilmedi. Gerçek fon öncesi bağımsız inceleme şart.
