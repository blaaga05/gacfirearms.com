# GAC accessory preview

Defender Handguard is a genuine noncritical accessory listing on /#rifle, using the supplied handguard artwork. No receiver listing or receiver cart features were added.

Catalog uses existing gac_merch_products RLS and adds category (merch or accessories) and price_pending. Apparel stays on Merch; accessories display on GAC AR. Defender has price_pending=true; a nonpayable sentinel cent satisfies the existing positive-price constraint but is never displayed as its price. Product/cart totals say Price pending until owner sets a real price. Any future checkout implementation must reject price_pending products and calculate fresh server totals. Checkout remains disabled and no payment/order/fulfillment operation is performed by this preview.

Admin > Merch & accessories supports details, price (blank = to be confirmed), size/option labels, page category, visibility, image URL and photo upload. Upload PNG/JPEG/WebP <=5 MB to public gac-product-images bucket, then Save product. Public URLs are appropriate for public product artwork only. Storage INSERT and metadata SELECT are owner-only; no UPDATE, overwrite, or DELETE policy is added. Random immutable paths avoid replacing an existing image. Changed product/logout invalidates stale upload responses. Catalog edits retain existing private owner authorization.

Verification: 66 Node tests pass. DOM smoke checks cover correct page/category rendering, pending price displays in product/cart, quantity/cart behavior, owner price save and immutable upload handoff. SQL rollback checks cover member upload denial, owner upload permission, published reads and preservation of catalog prices. No browser visual QA is available. No payment settings or member purchase history changed.
