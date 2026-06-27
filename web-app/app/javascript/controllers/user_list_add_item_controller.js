import { Controller } from "@hotwired/stimulus"

// Adds an existing listable to the current list from the list show page (02e).
//
// Listens for `autocomplete:selected` (dispatched by the AutocompleteComponent
// typeahead inside this element), POSTs the chosen listable to the 02a
// items#create endpoint, then reloads ONLY the `list_items` Turbo Frame so the
// new item appears without a full-page flash and the success toast stays visible.
//
// The /my/lists/:id show page is never cached, so the standard <meta> CSRF token
// is reliable here (no /user_list_state dance like the cached card widget).
export default class extends Controller {
  static values = { userListId: Number, listName: String }

  add(event) {
    const item = event.detail?.item
    const listableId = item?.value
    if (!listableId || this.submitting) return
    this.submitting = true
    this._create(listableId, item.text)
  }

  async _create(listableId, label) {
    try {
      const res = await fetch(`/user_lists/${this.userListIdValue}/items`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
          "X-CSRF-Token": this._csrf()
        },
        credentials: "same-origin",
        body: JSON.stringify({ user_list_item: { listable_id: listableId } })
      })
      const data = await res.json().catch(() => ({}))
      if (!res.ok) throw new Error(data.error?.message || "Failed to add item")

      // Update the shared user-list-state cache BEFORE reloading the frame, so
      // the new item's "on these lists" widget renders correctly the moment it
      // connects (the widget reads the cache synchronously on connect).
      this._syncState(data.user_list_item)
      this._toast("success", `Added “${label}” to ${this.listNameValue}`)
      this._resetInput()
      this._refreshList()
    } catch (err) {
      // Leave the list as-is (e.g. 409 duplicate) and let the user try again.
      this._toast("error", err.message || "Something went wrong")
    } finally {
      this.submitting = false
    }
  }

  // Reload just the item-list frame (count + rows) from the show action, which
  // re-renders it in the current view mode / sort / page. Falls back to a full
  // reload if the frame or Turbo is unavailable.
  _refreshList() {
    const frame = document.getElementById("list_items")
    if (!frame || typeof frame.reload !== "function") {
      window.location.reload()
    } else if (frame.src) {
      // Already navigated once (e.g. paginated): re-fetch whatever it shows now.
      frame.reload()
    } else {
      // First add: point the frame at the current page; setting src loads it.
      frame.src = window.location.href
    }
  }

  // Optimistically record the new membership in the singleton user-list-state
  // cache (mirrors the modal's _afterMutation) so the per-item widget shows the
  // item as "on this list". Falls back to a server refresh if the cache isn't
  // ready yet (rare: first visit before /user_list_state has returned).
  _syncState(item) {
    if (!item) return
    const stateCtrl = this._stateController()
    if (!stateCtrl) return

    if (!stateCtrl.state?.()) {
      stateCtrl.refresh?.()
      return
    }

    const type = item.listable_type
    const id = item.listable_id
    const current = (stateCtrl.state().memberships?.[type] || {})[String(id)] || []
    if (current.some((m) => m.list_id === item.user_list_id)) return

    stateCtrl.applyMutation({
      listableType: type,
      listableId: id,
      memberships: [...current, { list_id: item.user_list_id, item_id: item.id }]
    })
  }

  _stateController() {
    return window.Stimulus?.getControllerForElementAndIdentifier?.(document.body, "user-list-state") || null
  }

  // Clear the search box and refocus it so the owner can add another item.
  _resetInput() {
    const input = this.element.querySelector('input[type="search"]')
    const hidden = this.element.querySelector('input[type="hidden"]')
    if (hidden) hidden.value = ""
    if (input) {
      input.value = ""
      input.focus()
    }
  }

  _csrf() {
    return document.querySelector('meta[name="csrf-token"]')?.content || ""
  }

  _toast(type, message) {
    window.dispatchEvent(new CustomEvent("toast:show", { detail: { type, message } }))
  }
}
