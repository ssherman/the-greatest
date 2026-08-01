# == Schema Information
#
# Table name: users
#
#  id                       :bigint           not null, primary key
#  auth_data                :jsonb
#  auth_uid                 :string
#  display_name             :string
#  email                    :string
#  email_verified           :boolean          default(FALSE), not null
#  external_provider        :integer
#  external_provider_uid    :string
#  first_login_confirmation :boolean          default(FALSE), not null
#  goodreads_import         :jsonb
#  joined_email_list        :boolean          default(FALSE), not null
#  last_sign_in_at          :datetime
#  migrated                 :boolean          default(FALSE), not null
#  name                     :string
#  name_from_oauth          :string
#  old_encrypted_password   :string
#  old_user_data            :text
#  paid                     :boolean          default(FALSE), not null
#  photo_url                :string
#  provider_data            :text
#  role                     :integer          default(0), not null
#  sign_in_count            :integer
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  stripe_customer_id       :string
#
# Indexes
#
#  index_users_on_auth_uid               (auth_uid)
#  index_users_on_external_provider_uid  (external_provider_uid)
#  index_users_on_stripe_customer_id     (stripe_customer_id)
#
module LegacyBooks
  class User < Record
    self.table_name = "users"
  end
end
