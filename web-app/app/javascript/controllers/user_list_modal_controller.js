import { Controller } from "@hotwired/stimulus"

// Singleton modal controller. Listens for "user-list-modal:open" events and
// renders one row per UserList in the user's state, with a checkbox indicating
// membership. Toggling rows triggers add/remove. Submit creates a new custom list.
export default class extends Controller {
  static targets = [
    "title", "existingLists", "createDetails", "createForm", "nameInput",
    "descriptionInput", "publicInput", "submitButton", "formError"
  ]

  connect() {
    this._onOpen = this._onOpen.bind(this)
    window.addEventListener("user-list-modal:open", this._onOpen)
    this.openContext = null
  }

  disconnect() {
    window.removeEventListener("user-list-modal:open", this._onOpen)
  }

  _onOpen(event) {
    this.openContext = event.detail
    this._resetCreateForm()
    this._render()
    this.element.showModal?.()
  }

  // Resets the inline create form between opens so the disclosure isn't
  // surprisingly expanded and the Create button doesn't carry stale state.
  _resetCreateForm() {
    if (this.hasCreateDetailsTarget) this.createDetailsTarget.open = false
    if (this.hasNameInputTarget) this.nameInputTarget.value = ""
    if (this.hasDescriptionInputTarget) this.descriptionInputTarget.value = ""
    if (this.hasPublicInputTarget) this.publicInputTarget.checked = false
    this._setFormError(null)
    this.syncCreateButton()
  }

  // Toggles the Create button's disabled state based on whether a name has
  // been entered. Bound to the name input via data-action="input->...".
  syncCreateButton() {
    if (!this.hasSubmitButtonTarget || !this.hasNameInputTarget) return
    const empty = this.nameInputTarget.value.trim().length === 0
    this.submitButtonTarget.disabled = empty
  }

  _render() {
    if (!this.openContext) return
    const { listableType, listableTitle } = this.openContext
    if (this.hasTitleTarget) {
      this.titleTarget.textContent = listableTitle || ""
    }

    const state = this._state()
    if (!state) {
      this.existingListsTarget.innerHTML =
        `<p class="text-sm text-base-content/70">Sign in to manage your lists.</p>`
      return
    }

    const memberMap = this._memberMap(state)
    const subclassLists = state.lists.filter((l) => this._matchesListable(l.type, listableType))

    this.existingListsTarget.innerHTML = ""
    if (subclassLists.length === 0) {
      this.existingListsTarget.innerHTML =
        `<p class="text-sm text-base-content/70">No lists yet — create one below.</p>`
      return
    }

    subclassLists.forEach((list) => {
      // min-w-0 on the label lets the flex item shrink below content width;
      // break-words on the name span wraps long names instead of overflowing.
      const row = document.createElement("label")
      row.className = "label cursor-pointer justify-start items-start gap-3 py-1 min-w-0"
      row.innerHTML = `
        <input type="checkbox" class="checkbox checkbox-sm mt-0.5 shrink-0" data-list-id="${list.id}">
        <span class="label-text flex-1 min-w-0 break-words text-left">${this._escape(list.name)}</span>
      `
      const input = row.querySelector("input")
      input.checked = memberMap.has(list.id)
      input.addEventListener("change", () => this._toggle(list, input))
      this.existingListsTarget.appendChild(row)
    })
  }

  // Lookup map list_id → item_id for the current (type,id) pair.
  _memberMap(state) {
    const entries = (state?.memberships?.[this.openContext.listableType] || {})[String(this.openContext.listableId)] || []
    return new Map(entries.map((e) => [e.list_id, e.item_id]))
  }

  async _toggle(list, input) {
    const wantOn = input.checked
    input.disabled = true
    try {
      if (wantOn) {
        await this._add(list.id)
      } else {
        await this._remove(list.id)
      }
    } catch (err) {
      input.checked = !wantOn
      this._toast("error", err.message || "Something went wrong")
    } finally {
      input.disabled = false
    }
  }

  async _add(listId) {
    const headers = await this._headers()
    const res = await fetch(`/user_lists/${listId}/items`, {
      method: "POST",
      headers: headers,
      credentials: "same-origin",
      body: JSON.stringify({ user_list_item: { listable_id: this.openContext.listableId } })
    })
    const data = await res.json().catch(() => ({}))
    if (!res.ok) throw new Error(data.error?.message || "Failed to add")
    this._afterMutation({added: {list_id: listId, item_id: data.user_list_item?.id}})
    this._toast("success", `Added to ${this._listName(listId)}`)
  }

  async _remove(listId) {
    const itemId = this._findItemId(listId)
    if (!itemId) {
      // We have no record of this membership — refresh state and bail.
      await this._stateController()?.refresh()
      throw new Error("Couldn't find that item; please try again")
    }
    const headers = await this._headers()
    const res = await fetch(`/user_lists/${listId}/items/${itemId}`, {
      method: "DELETE",
      headers: headers,
      credentials: "same-origin"
    })
    if (!res.ok) {
      const data = await res.json().catch(() => ({}))
      throw new Error(data.error?.message || "Failed to remove")
    }
    this._afterMutation({removedListId: listId})
    this._toast("success", `Removed from ${this._listName(listId)}`)
  }

  async createList(event) {
    event.preventDefault()
    if (this.nameInputTarget.value.trim().length === 0) return
    this._setFormError(null)
    this.submitButtonTarget.disabled = true
    try {
      const body = {
        user_list: {
          type: this._listClassFor(this.openContext.listableType),
          name: this.nameInputTarget.value,
          description: this.descriptionInputTarget.value,
          public: this.publicInputTarget.checked,
          listable_id: this.openContext.listableId
        }
      }
      const headers = await this._headers()
      const res = await fetch("/user_lists", {
        method: "POST",
        headers: headers,
        credentials: "same-origin",
        body: JSON.stringify(body)
      })
      const data = await res.json()
      if (!res.ok) throw new Error(data.error?.message || "Failed to create list")
      const stateCtrl = this._stateController()
      const current = (stateCtrl.state()?.memberships?.[this.openContext.listableType] || {})[String(this.openContext.listableId)] || []
      const next = data.user_list_item
        ? [...current, {list_id: data.user_list.id, item_id: data.user_list_item.id}]
        : current
      stateCtrl.applyMutation({
        listableType: this.openContext.listableType,
        listableId: this.openContext.listableId,
        memberships: next,
        addedList: data.user_list
      })
      this._render()
      this._resetCreateForm()
      this._toast("success", `Created "${data.user_list.name}"`)
    } catch (err) {
      this._setFormError(err.message)
    } finally {
      this.syncCreateButton()
    }
  }

  // `added`: {list_id, item_id} | `removedListId`: integer
  _afterMutation({added, removedListId}) {
    const stateCtrl = this._stateController()
    const cur = stateCtrl.state()
    const current = (cur?.memberships?.[this.openContext.listableType] || {})[String(this.openContext.listableId)] || []
    let next = current.slice()
    if (added) next.push(added)
    if (removedListId) next = next.filter((m) => m.list_id !== removedListId)
    stateCtrl.applyMutation({
      listableType: this.openContext.listableType,
      listableId: this.openContext.listableId,
      memberships: next
    })
  }

  _matchesListable(listType, listableType) {
    // Map STI list class -> listable_type by convention.
    const map = {
      "Music::Albums::UserList": "Music::Album",
      "Music::Songs::UserList": "Music::Song",
      "Games::UserList": "Games::Game",
      "Movies::UserList": "Movies::Movie"
    }
    return map[listType] === listableType
  }

  _listClassFor(listableType) {
    const map = {
      "Music::Album": "Music::Albums::UserList",
      "Music::Song": "Music::Songs::UserList",
      "Games::Game": "Games::UserList",
      "Movies::Movie": "Movies::UserList"
    }
    return map[listableType]
  }

  // Resolves a UserListItem id from the bulk state for the modal's current
  // listable. The state response includes {list_id, item_id} tuples so this
  // doesn't need a separate lookup endpoint.
  _findItemId(listId) {
    const state = this._state()
    if (!state) return null
    return this._memberMap(state).get(listId) || null
  }

  _listName(listId) {
    return this._state()?.lists.find((l) => l.id === listId)?.name || "list"
  }

  _state() {
    return this._stateController()?.state?.() || null
  }

  _stateController() {
    return window.Stimulus?.getControllerForElementAndIdentifier?.(document.body, "user-list-state")
  }

  // The CDN-cached HTML's <meta name="csrf-token"> belongs to whoever rendered
  // the cache (or no one), so it's unreliable. The state controller fetches a
  // fresh per-session token via /user_list_state and exposes it here.
  async _headers() {
    const stateCtrl = this._stateController()
    const token = await stateCtrl?.ensureCsrf?.()
    return {
      "Content-Type": "application/json",
      Accept: "application/json",
      "X-CSRF-Token": token || ""
    }
  }

  _toast(type, message) {
    window.dispatchEvent(new CustomEvent("toast:show", { detail: { type, message } }))
  }

  _setFormError(message) {
    if (!this.hasFormErrorTarget) return
    if (message) {
      this.formErrorTarget.textContent = message
      this.formErrorTarget.classList.remove("hidden")
    } else {
      this.formErrorTarget.textContent = ""
      this.formErrorTarget.classList.add("hidden")
    }
  }

  _escape(s) {
    const div = document.createElement("div")
    div.textContent = s
    return div.innerHTML
  }
}
