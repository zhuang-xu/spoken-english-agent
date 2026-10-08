// Browser identity is established by the same-origin API, never by local storage.
export class AccountError extends Error {
  constructor(reason) {
    super(reason === "changed" ? "The signed-in account changed. Reload this page to continue." :
      reason === "required" ? "Your sign-in expired. Sign in again, then check your account." :
      reason === "forbidden" ? "This account does not have access to practice." :
      "Could not verify your account. Check your connection and try again.");
    this.reason = reason;
    this.status = reason === "required" ? 401 : reason === "forbidden" ? 403 : 0;
  }
}

const validAccountId = value => typeof value === "string" &&
  /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i.test(value);

export class AccountBoundary {
  constructor({ fetchImpl = (...args) => globalThis.fetch(...args), onState = () => {} } = {}) {
    this.fetchImpl = fetchImpl;
    this.onState = onState;
    this.accountId = null;
    this.state = "loading";
  }

  setState(state) {
    if (this.state === state) return;
    this.state = state;
    this.onState(state);
  }

  async check({ recover = false } = {}) {
    if (this.state === "changed") throw new AccountError("changed");
    if (["required", "forbidden"].includes(this.state) && !recover) throw new AccountError(this.state);
    let response;
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 10000);
    try {
      response = await this.fetchImpl("/me", { method: "GET", cache: "no-store",
        credentials: "same-origin", redirect: "manual", signal: controller.signal });
    } catch {
      if (this.state === "changed") throw new AccountError("changed");
      this.setState("unavailable");
      throw new AccountError("unavailable");
    } finally { clearTimeout(timer); }
    if (this.state === "changed") throw new AccountError("changed");
    if (["required", "forbidden"].includes(this.state) && !recover)
      throw new AccountError(this.state);
    if (response.status === 401 || response.status === 403 ||
        response.type === "opaqueredirect" || (response.status >= 300 && response.status < 400)) {
      const reason = response.status === 403 ? "forbidden" : "required";
      this.setState(reason);
      throw new AccountError(reason);
    }
    if (!response.ok) {
      this.setState("unavailable");
      throw new AccountError("unavailable");
    }
    let accountId;
    try { accountId = (await response.json()).account_id; }
    catch { accountId = null; }
    if (this.state === "changed") throw new AccountError("changed");
    if (["required", "forbidden"].includes(this.state) && !recover)
      throw new AccountError(this.state);
    if (!validAccountId(accountId)) {
      this.setState("unavailable");
      throw new AccountError("unavailable");
    }
    if (this.accountId && this.accountId !== accountId) {
      this.setState("changed");
      throw new AccountError("changed");
    }
    this.accountId = accountId;
    this.setState("ready");
    return accountId;
  }

  async require(accountId) {
    if (!accountId || this.accountId !== accountId) throw new AccountError("changed");
    return this.check();
  }

  observeResponse(response) {
    if (this.state === "changed") return response;
    if (response.status === 409 && response.headers?.get?.("X-Account-Changed") === "1")
      this.setState("changed");
    if (response.status === 401 || response.status === 403 ||
        response.type === "opaqueredirect" || (response.status >= 300 && response.status < 400))
      this.setState(response.status === 403 ? "forbidden" : "required");
    return response;
  }

  async fetchFor(accountId, url, init) {
    await this.require(accountId);
    const response = this.observeResponse(await this.fetchImpl(url, {
      ...init, credentials: "same-origin", redirect: "manual",
      headers: { ...init?.headers, "X-Expected-Account-ID": accountId },
    }));
    if (["changed", "required", "forbidden"].includes(this.state))
      throw new AccountError(this.state);
    return response;
  }
}
