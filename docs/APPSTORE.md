# App Store submission kit

Paste-ready metadata for App Store Connect, plus the privacy-label answers
and reviewer notes. The step-by-step submission checklist lives in
DEVELOPMENT.md ("Shipping to the App Store").

## Basics

| Field | Value |
|---|---|
| Name | FeedYu |
| Subtitle (en) | Tonight's pick from your lists |
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

Required: 6.9" (1320×2868, iPhone 17 Pro Max class) — one size is enough
since the app is iPhone-only and Apple scales down. 3–10 images.

Suggested set (capture via the launch-argument tab override, see
DEVELOPMENT.md): 1. Tonight card with a suggestion, 2. travel-budget
panel mid-adjustment, 3. Michelin tab with filters + card, 4. Uber Eats
tab with order button, 5. Settings lists. Real store data makes better
screenshots than seeded fixtures — capture from a device backup seeded
simulator, and keep screenshots out of git (they contain personal lists).
