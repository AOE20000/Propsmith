extends RefCounted
class_name ActivityTag
## The controlled vocabulary that lets one mobility system work on *any* annotated map.
##
## The problem this solves: a map's labels come from wherever the map came from — the
## PLATEAU `bldg:usage`（用途）values of the default map source, an OSM tag, a European
## building register, a hand-authored JSON, or a mod author typing Chinese into a text file.
## 「事務所」, "office", "Kantoorfunctie" and 「公司」 are the same activity, and behaviour
## cannot be written against four vocabularies.
##
## So every source is normalised into one small set of canonical activity tags here, and
## everything downstream — destination choice, activity patterns, route caching — only
## ever sees canonical tags. Adding a new map source means adding aliases to this table,
## not touching the behaviour layer. That is the whole reason the mobility core does not
## depend on any particular dataset or plugin.
##
## Normalisation is deliberately forgiving (case, spaces, hyphens, underscores,
## punctuation all ignored) because these strings come from data that was never written
## to a schema. An unrecognised label becomes `other` rather than an error: a map with a
## vocabulary we have never seen must still produce *some* sane behaviour.

const HOME: StringName = &"home"
const WORK: StringName = &"work"
const FOOD: StringName = &"food"
const SHOP: StringName = &"shop"
const SCHOOL: StringName = &"school"
const LEISURE: StringName = &"leisure"
const SERVICE: StringName = &"service"
const TRANSIT: StringName = &"transit"
## Where an unrecognised label lands. Also the universal last resort for fallback.
const OTHER: StringName = &"other"

## The canonical set, in a stable order so anything iterating it is deterministic.
const CANONICAL: Array[StringName] = [
	HOME, WORK, FOOD, SHOP, SCHOOL, LEISURE, SERVICE, TRANSIT, OTHER,
]

## Raw label -> canonical tag. Grouped by canonical tag for readability; the reverse
## index is built once, lazily, by `_alias_index()`.
##
## Covers the vocabularies this project actually expects to meet:
##   - **Japanese PLATEAU `bldg:usage` values** — the default map source. PLATEAU buildings
##     carry a semantic use type, which is what lets the tag-driven mobility layer run on a
##     real dataset without any trajectory data at all.
##   - Dutch building-register usage functions (`woonfunctie` …), kept because they cost
##     nothing and a user may still point the pipeline at another register.
##   - English OSM/Overture-style categories.
##   - Chinese, because a mod author annotating a map by hand is as legitimate a source as a
##     national register.
##
## The Japanese entries follow PLATEAU's `bldg:usage` labels. The exact value list should be
## taken from the PLATEAU product specification during M0 rather than trusted from here; an
## unrecognised value degrades to `other` and is reported, so a gap surfaces as thin
## behaviour on one activity rather than as a failure.
const ALIASES: Dictionary = {
	HOME: [
		"home", "house", "housing", "residence", "residential", "dwelling", "apartment",
		"flat", "living", "accommodation", "lodging", "hostel", "woonfunctie", "woonobject",
		# Lodging is where someone stays overnight, so it belongs with home rather than with
		# food; "hotel" used to sit in the food group by mistake.
		"hotel", "logiesfunctie",
		"住宅", "共同住宅", "住居", "一戸建て", "マンション", "アパート", "ホテル", "宿泊施設", "旅館",
		"家", "住处", "居住", "住房", "公寓", "小区",
	],
	WORK: [
		"work", "workplace", "office", "company", "business", "corporate", "industrial",
		"industry", "warehouse", "factory", "kantoor", "kantoorfunctie", "industriefunctie",
		"bedrijf",
		"事務所", "工場", "倉庫", "会社", "オフィス", "ビル", "官公庁", "庁舎",
		"公司", "办公室", "写字楼", "企业", "上班", "厂", "工业",
	],
	FOOD: [
		"food", "restaurant", "cafe", "cafeteria", "bar", "pub", "eatery", "dining", "diner",
		"fastfood", "snack", "takeaway", "bistro",
		"飲食店", "レストラン", "食堂", "喫茶店", "カフェ", "居酒屋", "料理店", "そば屋",
		"饭店", "餐厅", "餐馆", "咖啡", "饮食", "小吃", "酒吧",
	],
	SHOP: [
		"shop", "shops", "store", "supermarket", "grocery", "market", "retail",
		"convenience", "mall", "bakery", "butcher", "winkel", "winkelfunctie",
		"店舗", "商店", "小売店", "スーパー", "コンビニ", "市場", "百貨店",
		"商店", "超市", "零售", "便利店", "商场",
	],
	SCHOOL: [
		"school", "university", "college", "education", "academy", "campus",
		"kindergarten", "library", "onderwijsfunctie", "celfunctie",
		"学校", "小学校", "中学校", "高等学校", "大学", "幼稚園", "保育園", "図書館", "教育施設",
		"学院", "教育", "幼儿园",
	],
	LEISURE: [
		"leisure", "park", "garden", "sport", "sports", "gym", "fitness", "museum",
		"cinema", "theatre", "theater", "recreation", "playground", "sportfunctie",
		"bijeenkomstfunctie",
		"公園", "体育館", "博物館", "美術館", "劇場", "映画館", "遊技場", "グラウンド", "レジャー施設",
		"体育馆", "健身房", "影院", "娱乐", "广场",
	],
	SERVICE: [
		"service", "services", "hospital", "clinic", "doctor", "pharmacy", "bank",
		"government", "municipal", "post", "police", "fire", "healthcare",
		"gezondheidszorgfunctie", "overige gebruiksfunctie",
		"病院", "医院", "診療所", "薬局", "銀行", "郵便局", "警察署", "消防署", "神社", "寺院",
		"教会", "福祉施設",
		"诊所", "药房", "政府", "派出所", "服务",
	],
	TRANSIT: [
		"transit", "station", "stations", "stop", "busstop", "tram", "metro", "subway",
		"railway", "platform", "airport", "ferry",
		"駅舎", "駅", "空港", "港湾", "バス停", "停留所", "鉄道",
		"车站", "公交站", "地铁站", "火车站", "码头", "交通",
	],
	OTHER: [
		"other", "unknown", "misc", "unspecified",
		"その他", "不明", "未設定",
		"其他", "未知",
	],
}

## Per-tag fallback ladder used when a map simply has no destination of the requested
## kind. Order matters: nearest allowed concept first, `other` last as the universal net.
##
## This is what makes the behaviour layer survive an arbitrary map. A map with no
## restaurant at all must not produce an agent that stands still forever.
const FALLBACKS: Dictionary = {
	FOOD: [FOOD, SHOP, LEISURE, SERVICE, OTHER],
	SHOP: [SHOP, FOOD, LEISURE, SERVICE, OTHER],
	LEISURE: [LEISURE, FOOD, SHOP, OTHER],
	SCHOOL: [SCHOOL, SERVICE, OTHER],
	SERVICE: [SERVICE, SCHOOL, SHOP, OTHER],
	TRANSIT: [TRANSIT, WORK, OTHER],
	WORK: [WORK, SERVICE, OTHER],
	HOME: [HOME, OTHER],
	OTHER: [OTHER],
}


## Fold a raw label into a canonical tag. Never fails: an unknown label is `other`.
static func normalize(raw: String) -> StringName:
	var key: String = _squash(raw)
	if key.is_empty():
		return OTHER
	if CANONICAL.has(StringName(key)) and key == "other":
		return OTHER
	var index: Dictionary = _alias_index()
	if index.has(key):
		return index[key]
	# A canonical name used directly is always valid, e.g. a hand-written "work".
	if CANONICAL.has(StringName(key)):
		return StringName(key)
	return OTHER


## Canonical tags that may stand in for `tag`, nearest concept first, always ending at
## `other`. The first entry is the tag itself.
static func fallback_ladder(tag: StringName) -> Array[StringName]:
	var ladder: Array[StringName] = []
	for entry: Variant in (FALLBACKS.get(tag, [tag, OTHER]) as Array):
		ladder.append(StringName(entry))
	if not ladder.has(tag):
		ladder.push_front(tag)
	if not ladder.has(OTHER):
		ladder.append(OTHER)
	return ladder


## Whether `tag` is a canonical activity tag.
static func is_canonical(tag: StringName) -> bool:
	return CANONICAL.has(tag)


## Raw labels known to fold into `tag`, including the tag's own name. Lets a map source
## tell an author which spellings are already understood.
static func aliases_for(tag: StringName) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray([String(tag)])
	for entry: Variant in (ALIASES.get(tag, []) as Array):
		out.append(String(entry))
	return out


## Lowercase, drop every separator and punctuation mark. Data written by humans and by four
## different registers disagrees about all of these, so none of it is allowed to matter.
##
## Separators are **removed**, not turned into an underscore. That single choice is what makes
## `"fast food"`, `"fast-food"`, `"fast_food"` and `"fastfood"` the same label — turning them
## into `_` would still split the first three from the fourth, which is exactly the case a
## hand-annotated map produces.
static func _squash(raw: String) -> String:
	var lowered: String = raw.strip_edges().to_lower()
	var out: String = ""
	for index: int in lowered.length():
		var character: String = lowered[index]
		var code: int = character.unicode_at(0)
		# Non-ASCII (CJK and friends) is significant content, kept verbatim.
		if code >= 0x80:
			out += character
			continue
		if (code >= 48 and code <= 57) or (code >= 97 and code <= 122):
			out += character
			continue
		# Everything else — spaces, hyphens, underscores, slashes, punctuation — is dropped.
	return out


## The reverse index, built once. `static var` because the table is immutable: rebuilding
## it per call would put a dictionary allocation inside every destination lookup.
static var _cached_index: Dictionary = {}
static var _index_built: bool = false


static func _alias_index() -> Dictionary:
	if _index_built:
		return _cached_index
	var index: Dictionary = {}
	for key: Variant in ALIASES:
		var canonical: StringName = key
		for entry: Variant in (ALIASES[key] as Array):
			index[_squash(String(entry))] = canonical
		# The canonical name itself is always an alias for itself.
		index[String(canonical)] = canonical
	_cached_index = index
	_index_built = true
	return _cached_index
