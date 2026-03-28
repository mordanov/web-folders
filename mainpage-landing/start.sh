#!/bin/sh
set -eu

: "${MAINPAGE_PRIMARY_DOMAIN:?Missing MAINPAGE_PRIMARY_DOMAIN}"
: "${MAINPAGE_TITLE:?Missing MAINPAGE_TITLE}"
MAINPAGE_BROWSER_TITLE="${MAINPAGE_BROWSER_TITLE:-$MAINPAGE_TITLE}"
# MAINPAGE_LINK_DOMAIN can override the base domain used in link URLs.
MAINPAGE_LINK_DOMAIN="${MAINPAGE_LINK_DOMAIN:-$MAINPAGE_PRIMARY_DOMAIN}"

is_enabled() {
  value=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
  case "$value" in
    1|true|yes|on)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

configure_link() {
  link_key="$1"
  subdomain="$2"
  enabled_flag="$3"

  if is_enabled "$enabled_flag"; then
    href="https://${subdomain}.${MAINPAGE_LINK_DOMAIN}"
    class=""
    title=""
    aria_disabled="false"
    tabindex="0"
  else
    href="#"
    class="disabled"
    title="&#1042; &#1088;&#1072;&#1079;&#1088;&#1072;&#1073;&#1086;&#1090;&#1082;&#1077;"
    aria_disabled="true"
    tabindex="-1"
  fi

  eval "export ${link_key}_LINK_HREF=\"$href\""
  eval "export ${link_key}_LINK_CLASS=\"$class\""
  eval "export ${link_key}_LINK_TITLE=\"$title\""
  eval "export ${link_key}_LINK_ARIA_DISABLED=\"$aria_disabled\""
  eval "export ${link_key}_LINK_TABINDEX=\"$tabindex\""
}

configure_link "RECIPES" "recipes" "${MAINPAGE_ENABLE_RECIPES:-1}"
configure_link "REMINDERS" "reminders" "${MAINPAGE_ENABLE_REMINDERS:-1}"
configure_link "FAMILYPHOTO" "familyphoto" "${MAINPAGE_ENABLE_FAMILYPHOTO:-1}"
configure_link "HOME" "home" "${MAINPAGE_ENABLE_HOME:-1}"

configure_link "NEWS" "news" "${MAINPAGE_ENABLE_NEWS:-1}"
if is_enabled "${MAINPAGE_ENABLE_NEWS:-1}"; then
  NEWS_LINK_TITLE="&#1054;&#1090;&#1082;&#1088;&#1099;&#1090;&#1100; &#1083;&#1077;&#1085;&#1090;&#1091; &#1085;&#1086;&#1074;&#1086;&#1089;&#1090;&#1077;&#1081;"
fi

# --- budget-site link ---
BUDGET_LINK_HREF="https://${BUDGET_PRIMARY_DOMAIN:-budget.mainpage.ru}"
BUDGET_LINK_CLASS="disabled"
BUDGET_LINK_TITLE="Скоро (бюджет)"
BUDGET_LINK_ARIA_DISABLED="false"
BUDGET_LINK_TABINDEX="0"

escape_sed() {
  printf '%s' "$1" | sed 's/[\\&|]/\\&/g'
}

# Render a runtime index.html from template placeholders.
sed \
  -e "s|__MAINPAGE_TITLE__|$(escape_sed "$MAINPAGE_TITLE")|g" \
  -e "s|__MAINPAGE_BROWSER_TITLE__|$(escape_sed "$MAINPAGE_BROWSER_TITLE")|g" \
  -e "s|__RECIPES_LINK_HREF__|$(escape_sed "$RECIPES_LINK_HREF")|g" \
  -e "s|__RECIPES_LINK_CLASS__|$(escape_sed "$RECIPES_LINK_CLASS")|g" \
  -e "s|__RECIPES_LINK_TITLE__|$(escape_sed "$RECIPES_LINK_TITLE")|g" \
  -e "s|__RECIPES_LINK_ARIA_DISABLED__|$(escape_sed "$RECIPES_LINK_ARIA_DISABLED")|g" \
  -e "s|__RECIPES_LINK_TABINDEX__|$(escape_sed "$RECIPES_LINK_TABINDEX")|g" \
  -e "s|__REMINDERS_LINK_HREF__|$(escape_sed "$REMINDERS_LINK_HREF")|g" \
  -e "s|__REMINDERS_LINK_CLASS__|$(escape_sed "$REMINDERS_LINK_CLASS")|g" \
  -e "s|__REMINDERS_LINK_TITLE__|$(escape_sed "$REMINDERS_LINK_TITLE")|g" \
  -e "s|__REMINDERS_LINK_ARIA_DISABLED__|$(escape_sed "$REMINDERS_LINK_ARIA_DISABLED")|g" \
  -e "s|__REMINDERS_LINK_TABINDEX__|$(escape_sed "$REMINDERS_LINK_TABINDEX")|g" \
  -e "s|__FAMILYPHOTO_LINK_HREF__|$(escape_sed "$FAMILYPHOTO_LINK_HREF")|g" \
  -e "s|__FAMILYPHOTO_LINK_CLASS__|$(escape_sed "$FAMILYPHOTO_LINK_CLASS")|g" \
  -e "s|__FAMILYPHOTO_LINK_TITLE__|$(escape_sed "$FAMILYPHOTO_LINK_TITLE")|g" \
  -e "s|__FAMILYPHOTO_LINK_ARIA_DISABLED__|$(escape_sed "$FAMILYPHOTO_LINK_ARIA_DISABLED")|g" \
  -e "s|__FAMILYPHOTO_LINK_TABINDEX__|$(escape_sed "$FAMILYPHOTO_LINK_TABINDEX")|g" \
  -e "s|__HOME_LINK_HREF__|$(escape_sed "$HOME_LINK_HREF")|g" \
  -e "s|__HOME_LINK_CLASS__|$(escape_sed "$HOME_LINK_CLASS")|g" \
  -e "s|__HOME_LINK_TITLE__|$(escape_sed "$HOME_LINK_TITLE")|g" \
  -e "s|__HOME_LINK_ARIA_DISABLED__|$(escape_sed "$HOME_LINK_ARIA_DISABLED")|g" \
  -e "s|__HOME_LINK_TABINDEX__|$(escape_sed "$HOME_LINK_TABINDEX")|g" \
  -e "s|__NEWS_LINK_HREF__|$(escape_sed "$NEWS_LINK_HREF")|g" \
  -e "s|__NEWS_LINK_CLASS__|$(escape_sed "$NEWS_LINK_CLASS")|g" \
  -e "s|__NEWS_LINK_TITLE__|$(escape_sed "$NEWS_LINK_TITLE")|g" \
  -e "s|__NEWS_LINK_ARIA_DISABLED__|$(escape_sed "$NEWS_LINK_ARIA_DISABLED")|g" \
  -e "s|__NEWS_LINK_TABINDEX__|$(escape_sed "$NEWS_LINK_TABINDEX")|g" \
  -e "s|__BUDGET_LINK_HREF__|$(escape_sed "$BUDGET_LINK_HREF")|g" \
  -e "s|__BUDGET_LINK_CLASS__|$(escape_sed "$BUDGET_LINK_CLASS")|g" \
  -e "s|__BUDGET_LINK_TITLE__|$(escape_sed "$BUDGET_LINK_TITLE")|g" \
  -e "s|__BUDGET_LINK_ARIA_DISABLED__|$(escape_sed "$BUDGET_LINK_ARIA_DISABLED")|g" \
  -e "s|__BUDGET_LINK_TABINDEX__|$(escape_sed "$BUDGET_LINK_TABINDEX")|g" \
  /usr/share/nginx/html/index.html.template > /tmp/index.html
mv /tmp/index.html /usr/share/nginx/html/index.html

exec nginx -g 'daemon off;'
