import { createHash, randomBytes } from 'crypto';
import { createServer, Server } from 'http';
import { APIRequestContext } from '@playwright/test';

// A throwaway OAuth client for the authorize-page specs: registered the way a
// real MCP client registers itself (Dynamic Client Registration), with a
// loopback callback the test listens on, so the browser lands on it and the
// test reads the code and state off that URL.
export type OauthClient = {
  clientId: string;
  redirectUri: string;
  callbackPattern: string;
  state: string;
  authorizeUrl: string;
};

export async function registerClient(request: APIRequestContext, port: number): Promise<OauthClient> {
  const redirectUri = `http://127.0.0.1:${port}/callback`;
  const response = await request.post('/api/oauth/register', {
    data: { redirect_uris: [redirectUri], client_name: 'E2E client' },
  });
  if (response.status() !== 201) throw new Error(`registration failed: ${response.status()}`);
  const { client_id: clientId } = await response.json();

  const verifier = randomBytes(32).toString('base64url');
  const challenge = createHash('sha256').update(verifier).digest('base64url');
  const state = randomBytes(12).toString('hex');
  const query = new URLSearchParams({
    client_id: clientId,
    redirect_uri: redirectUri,
    response_type: 'code',
    state,
    scope: 'books:read',
    code_challenge: challenge,
    code_challenge_method: 'S256',
  });

  return {
    clientId,
    redirectUri,
    callbackPattern: `http://127.0.0.1:${port}/callback**`,
    state,
    authorizeUrl: `/oauth/authorize?${query.toString()}`,
  };
}

// A real listener on the callback port, as Claude Code and Codex run one. The
// browser makes a genuine navigation to it, so the test sees what a client
// would: the URL carries the code or error and the state. (page.route did not
// work as a stand-in: the redirected hop came back net::ERR_ABORTED.)
export async function startCallbackServer(port: number): Promise<Server> {
  const server = createServer((_req, res) => {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end('callback');
  });
  await new Promise<void>((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, '127.0.0.1', resolve);
  });
  return server;
}
