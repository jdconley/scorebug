// The privacy policy and terms of service. Keep them true to what the code does: when data
// handling changes (what's stored, who processes it, how long it's kept), update these too.
import { html } from 'hono/html';

export const LEGAL_UPDATED = 'November 16, 2026';

const GOOGLE_PRIVACY = 'https://policies.google.com/privacy';
const GOOGLE_PERMISSIONS = 'https://myaccount.google.com/permissions';
const GOOGLE_USER_DATA_POLICY = 'https://developers.google.com/terms/api-services-user-data-policy';
const YOUTUBE_TERMS = 'https://www.youtube.com/t/terms';

export const privacyBody = (contact: string) => html`
  <h1>Privacy policy</h1>
  <p class="muted">Last updated ${LEGAL_UPDATED}</p>
  <p>
    Scorebug is an iPhone app and web service at scorebug.live that streams volleyball matches to
    YouTube with the score on screen. Conley Chaos LLC ("we") runs it. This policy explains what
    Scorebug collects, why, and how to have it removed.
  </p>

  <h2>What we collect</h2>
  <ul>
    <li>
      <strong>Your Google account basics.</strong> When you sign in with Google, we receive and keep
      your name, email address, profile picture link, and Google account ID.
    </li>
    <li>
      <strong>Team and match data.</strong> Team names, colors and members, invites you send,
      matches, scores, and the names of the devices you sign in on.
    </li>
    <li>
      <strong>YouTube connection.</strong> When you connect a YouTube channel, we keep the channel's
      ID and name and the OAuth tokens Google issues for it. Refresh tokens are stored encrypted.
    </li>
    <li>
      <strong>Service logs.</strong> Cloudflare, which hosts Scorebug, processes your IP address to
      deliver and protect the service. Our request and error logs are kept for a few days.
    </li>
  </ul>
  <p>
    We don't use advertising or analytics trackers, and the website sets no tracking cookies. The
    app keeps a sign-in token on your device.
  </p>

  <h2>How we use YouTube</h2>
  <p>
    Scorebug uses YouTube API Services. With your permission, it uses the YouTube Data API to see
    the channels on your Google account, and to create, update and end live broadcasts and live
    streams on the channel you pick, so your matches go live there. It doesn't read your other
    videos, comments or watch history, and it doesn't post anything except the broadcasts you start.
  </p>
  <p>
    By using Scorebug's YouTube features you agree to the
    <a href="${YOUTUBE_TERMS}">YouTube Terms of Service</a>. Google's use of your data is covered by
    the <a href="${GOOGLE_PRIVACY}">Google Privacy Policy</a>.
  </p>
  <p>
    Scorebug's use and transfer of information received from Google APIs adheres to the
    <a href="${GOOGLE_USER_DATA_POLICY}">Google API Services User Data Policy</a>, including the
    Limited Use requirements.
  </p>

  <h2>Video</h2>
  <p>
    Video from your iPhone goes to Cloudflare, which adds the scoreboard and sends the stream to
    YouTube. Scorebug doesn't record or store the video. YouTube keeps the broadcast according to
    your channel's settings.
  </p>

  <h2>Sharing</h2>
  <p>
    We don't sell your data or share it for advertising. It goes only to the services that run
    Scorebug: Cloudflare (hosting and video) and Google (sign-in and YouTube). Members of a team see
    each other's names, email addresses and pictures, and the team's matches. We'd disclose data if
    the law required it.
  </p>

  <h2>Removing access and deleting your data</h2>
  <ul>
    <li>
      Remove Scorebug's access to your Google account and YouTube channel at any time at
      <a href="${GOOGLE_PERMISSIONS}">myaccount.google.com/permissions</a>. Scorebug then can't
      reach your channel.
    </li>
    <li>
      To delete your Scorebug account and its data, email
      <a href="mailto:${contact}">${contact}</a> from the address you sign in with. We delete it,
      including any stored YouTube tokens, within 30 days, and confirm by email.
    </li>
  </ul>

  <h2>Children</h2>
  <p>
    Scorebug accounts are for adults: coaches, parents and team staff. The service isn't directed to
    children under 13, and we don't knowingly collect their personal information. Players appear in
    the video you stream; see the <a href="/terms">terms</a> for your responsibilities.
  </p>

  <h2>Security and changes</h2>
  <p>
    Data is encrypted in transit, and sign-in tokens are stored only as hashes. If this policy
    changes, we'll update the date above, and tell beta users by email about significant changes.
  </p>

  <h2>Contact</h2>
  <p>Conley Chaos LLC · <a href="mailto:${contact}">${contact}</a></p>
`;

export const termsBody = (contact: string) => html`
  <h1>Terms of service</h1>
  <p class="muted">Last updated ${LEGAL_UPDATED}</p>
  <p>
    These terms cover the Scorebug app and the service at scorebug.live, run by Conley Chaos LLC
    ("we"). By using Scorebug you agree to them. Scorebug's source code is open under the MIT
    license; these terms are about the hosted service.
  </p>

  <h2>A free private beta</h2>
  <p>
    Scorebug is a free, invite-only beta. It may change, break, or stop at any time, including in
    the middle of a match. It's provided "as is" and "as available", without warranties of any kind,
    express or implied, including fitness for a particular purpose. Don't rely on it for anything
    you can't afford to miss.
  </p>

  <h2>Your account</h2>
  <p>
    You sign in with Google and must be at least 18. You're responsible for what happens under your
    account and on teams you own, including who you invite.
  </p>

  <h2>Your right to stream</h2>
  <p>
    You're responsible for having the right to film and stream what you point Scorebug at. That
    includes following the rules of the gym, venue, league or tournament, getting consent from
    parents or guardians where it's needed to show minors, and respecting anyone who asks not to be
    filmed. You're responsible for everything you stream, including music or other content in it.
  </p>

  <h2>YouTube</h2>
  <p>
    Streams go to your own YouTube channel, under your control. When you use Scorebug with YouTube
    you agree to the <a href="${YOUTUBE_TERMS}">YouTube Terms of Service</a> and are responsible for
    your channel's settings, such as audience and visibility. See the
    <a href="/privacy">privacy policy</a> for how Scorebug uses YouTube.
  </p>

  <h2>Acceptable use</h2>
  <p>Don't use Scorebug to:</p>
  <ul>
    <li>break the law or anyone else's rights;</li>
    <li>stream content that harasses, sexualizes or endangers anyone, especially minors;</li>
    <li>
      interfere with the service, get around its limits, or access teams, matches or accounts that
      aren't yours.
    </li>
  </ul>

  <h2>Ending access</h2>
  <p>
    You can stop using Scorebug at any time and ask us to delete your data. We can suspend or end
    your access at any time, for example for breaking these terms, or by ending the beta.
  </p>

  <h2>Liability</h2>
  <p>
    To the fullest extent the law allows, Conley Chaos LLC isn't liable for indirect, incidental or
    consequential damages, or for lost streams, recordings or data, and our total liability for any
    claim about Scorebug is limited to US $50.
  </p>

  <h2>Changes</h2>
  <p>
    We may update these terms. We'll change the date above, and tell beta users by email about
    significant changes. Using Scorebug after a change means you accept it.
  </p>

  <h2>Contact</h2>
  <p>Conley Chaos LLC · <a href="mailto:${contact}">${contact}</a></p>
`;
