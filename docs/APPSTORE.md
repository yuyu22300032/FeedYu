# App Store submission kit

Paste-ready metadata for App Store Connect, plus the privacy-label answers
and reviewer notes. The step-by-step submission checklist lives in
DEVELOPMENT.md ("Shipping to the App Store").

## Basics

| Field | Value |
|---|---|
| Name | FeedYu |
| Subtitle (en) | Tonight's pick from your lists |
| Subtitle (zh-Hant) | 今晚吃什麼？從口袋名單挑一家 |
| Subtitle (ja) | 今夜の一軒を、あなたのリストから |
| Bundle ID | com.yuyu.FeedYu |
| SKU | feedyu-ios |
| Primary category | Food & Drink |
| Secondary category | Lifestyle |
| Age rating | 4+ (nothing objectionable) |
| Price | Free |
| Privacy policy URL | https://yuyu22300032.github.io/FeedYu/privacy.html |
| Support URL | https://github.com/yuyu22300032/FeedYu |
| Marketing URL (optional) | https://yuyu22300032.github.io/FeedYu/guide.html |

## Description (en-US)

You saved hundreds of restaurants on Google Maps — and still can't decide
where to eat. FeedYu picks one for you: from your own saved lists, close
enough for tonight.

TONIGHT'S PICK
Share any Google Maps list to FeedYu once, and it suggests one restaurant
at a time — never repeating until you've seen everything in range. Not
feeling it? One tap rolls another.

A TRAVEL BUDGET, NOT A MAP
Tell it how far you'll go: straight-line distance, walking minutes, or
driving minutes in current traffic (checked against real routes, not
guesses). Suggestions always fit.

THE WHOLE MICHELIN GUIDE, BUILT IN
Every tier worldwide — stars, Bib Gourmand, Selected — with local-language
names (鮨さいとう, not "Sushi Saito"), price filters, and listing history
back to 2022. No setup needed.

STAYING IN?
The Uber Eats tab suggests from the same lists, but only restaurants
verified orderable right now — the button drops you inside the store,
ready to order.

PRIVATE BY ARCHITECTURE
No account. No servers. Your lists and your location never leave your
phone. Open source under the MIT license.

- Import via the share sheet or Google Takeout (starred places too)
- Keep up to 20 lists; toggle each per tab without deleting
- Tap any suggestion's photo to open it straight in Google Maps
- Hide places you never want suggested again
- English, 繁體中文, 日本語

## Description (zh-Hant)

你在 Google 地圖存了幾百家餐廳，卻還是不知道晚餐吃哪家。FeedYu 幫你決定：
從你自己的口袋名單裡，挑一家今晚到得了的。

今晚吃什麼
把 Google 地圖清單分享給 FeedYu 一次，它就會一次推薦一家餐廳——在範圍內
的店全部看過之前絕不重複。不想吃這家？一鍵換下一家。

用「多遠」當條件
直線距離、步行分鐘數，或依「目前路況」計算的開車分鐘數（用真實路線驗證，
不是用猜的）。推薦永遠在你願意跑的範圍內。

內建完整米其林指南
全球所有等級——星級、必比登、入選——顯示在地語言店名、價位篩選，以及
2022 年起的入選紀錄。不用任何設定。

想叫外送？
Uber Eats 分頁從同樣的清單推薦，但只推「現在真的訂得到」的店——按鈕直接
帶你進店家頁面下單。

隱私是架構，不是承諾
沒有帳號、沒有伺服器。你的清單和位置永遠不離開你的手機。MIT 授權開源。

## Description (ja)

Google マップに保存した何百軒ものレストラン。それでも今夜の店が決まらない。
FeedYu が代わりに選びます——あなた自身のリストから、今夜行ける距離で。

今晩どこ行く？
Google マップのリストを一度シェアするだけ。範囲内の店を全部見るまで同じ店は
二度と出ません。ピンとこなければワンタップで次へ。

「どこまで行けるか」で絞り込み
直線距離、徒歩の分数、または現在の交通状況での運転分数（実際のルートで検証）。

ミシュランガイド全掲載店を内蔵
世界中の星付き・ビブグルマン・セレクテッドを現地語の店名で。価格帯フィルター、
2022 年からの掲載履歴も。設定は不要。

出前の気分なら
Uber Eats タブは同じリストから「いま実際に注文できる店」だけを提案。ボタン
ひとつで店舗ページへ。

プライバシーは設計そのもの
アカウントなし、サーバーなし。リストも位置情報も端末の外に出ません。MIT
ライセンスのオープンソース。

## Promotional text (≤170 chars, editable without a new build)

- **en:** Stop scrolling your saved places. FeedYu picks tonight's
  restaurant from your own Google Maps lists — within walking or driving
  reach, checked in live traffic.
- **zh-Hant:** 別再滑收藏清單了。FeedYu 從你的 Google 地圖口袋名單，挑出今晚
  吃的那一家——走路或開車都到得了，依即時路況推薦。
- **ja:** 保存したお店リストを眺めるのはもう終わり。FeedYu が Google マップの
  リストから今夜の一軒を選びます。徒歩や車で行ける範囲、リアルタイムの交通状況で。

## Keywords (en, ≤100 chars)

`restaurant,picker,tonight,michelin,saved,places,list,dinner,random,nearby,foodie,delivery`

## Privacy label (App Store Connect questionnaire)

- Data collection: **"Data Not Collected"** — answer No to every category.
  Location is *used* on-device but not collected/transmitted to the
  developer, which under Apple's definitions means it is not "collected".
- Tracking: No.

## App Review notes (paste into the review notes field)

> FeedYu suggests restaurants from the user's own saved Google Maps lists
> and the public Michelin Guide dataset. No account or login is needed —
> the app works immediately. To test the import flow: open any shared
> Google Maps list link and share it to FeedYu, or just use the built-in
> Michelin tab, which needs no setup. Location permission is used only to
> filter suggestions by distance; all data stays on-device (see privacy
> policy). We have written confirmation from Google and Uber that our use
> of their public pages is acceptable; happy to forward it on request.

Attach the Google/Uber permission emails as review attachments if the
reviewer asks about third-party content (guideline 5.2.2).

## Screenshots

Capture at 6.9" (1320×2868, iPhone 17 Pro Max class). **App Store Connect
may only offer a 6.5-inch slot** (it did for v1.0: accepted sizes
1242×2688 / 1284×2778) — convert with
`ffmpeg -i in.png -vf "scale=1284:-1,crop=1284:2778" out.png`
(6 px shaved top/bottom, invisible). App Previews at 886×1920 are valid
for both display classes. 3–10 images per localization; each localization
gets its own media set.

Suggested set (capture via the launch-argument tab override, see
DEVELOPMENT.md): 1. Tonight card with a suggestion, 2. travel-budget
panel mid-adjustment, 3. Michelin tab with filters + card, 4. Uber Eats
tab with order button, 5. Settings lists. Real store data makes better
screenshots than seeded fixtures — capture from a device backup seeded
simulator, and keep screenshots out of git (they contain personal lists).

App Previews (up to 3 per localization, 15–30 s): v1.1 adds a second
"easy setup" preview per language
(`~/Desktop/FeedYu-AppStore/preview/FeedYu-Setup{,-en,-ja}.mp4`, 24.3 s)
filmed from the onboarding guide's import pages — the
`testSetupChoreography` take plus the AVFoundation frame-extraction
pipeline (see DEVELOPMENT.md "App Preview video"). Upload order per
locale: feature tour first, setup second.

## Submission answers of record (v1.0, submitted 2026-07-09)

Answers given in App Store Connect that future versions inherit or repeat:

- **Content Rights:** contains third-party content → Yes, "I have all
  necessary rights" (open michelin-my-maps dataset license + written
  permission emails from Google and Uber — keep those emails).
- **Digital Services Act:** declared **non-trader** (individual, free
  app, no revenue).
- **Sign-In Information:** "Sign-in required" unchecked — no accounts.
- **Routing App Coverage File:** empty (navigation is handed off to
  Google/Apple Maps).
- **App Encryption:** handled by `ITSAppUsesNonExemptEncryption = false`
  in project.yml — the upload never asks.
- **Release option:** Manually release this version.
- **China mainland:** not distributed (no ICP filing).
- **Reviewer attachments:** the Google/Uber permission emails (PDF),
  attached proactively for guideline 5.2.2.
