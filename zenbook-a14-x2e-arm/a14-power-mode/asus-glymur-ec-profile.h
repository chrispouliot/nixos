/* SPDX-License-Identifier: GPL-2.0-only */
/* Local UX3407NA integration: EC presets only, not Windows PEP power limits. */
#include <linux/of.h>

static int asus_ec_profile_write_locked(struct asus_ec *ec, int profile)
{
	int ret;

	lockdep_assert_held(&ec->lock);
	ret = i2c_smbus_write_byte_data(ec->client, 0x24, profile);
	ec->profile_last_error = ret < 0 ? ret : 0;
	if (ret >= 0)
		ec->profile_last_requested = profile;
	return ret < 0 ? ret : 0;
}

static int asus_ec_profile_apply_locked(struct asus_ec *ec, int profile)
{
	int ret;

	/* Use the same normal -> quiet sequence validated in the timed trial. */
	if (profile == 1) {
		ret = asus_ec_profile_write_locked(ec, 0);
		if (ret)
			return ret;
	}
	return asus_ec_profile_write_locked(ec, profile);
}

static ssize_t fan_profile_show(struct device *dev,
			       struct device_attribute *attr, char *buf)
{
	struct asus_ec *ec = dev_get_drvdata(dev);

	guard(mutex)(&ec->lock);
	/* These are software request records, not firmware readback. */
	return sysfs_emit(buf, "desired=%d last_requested=%d last_error=%d suspended=%u\n",
			  ec->profile_desired, ec->profile_last_requested,
			  ec->profile_last_error, ec->profile_suspended);
}

static ssize_t fan_profile_store(struct device *dev,
				struct device_attribute *attr,
				const char *buf, size_t count)
{
	struct asus_ec *ec = dev_get_drvdata(dev);
	unsigned int profile;
	int ret;

	if (kstrtouint(buf, 0, &profile) || profile > 1)
		return -EINVAL;
	guard(mutex)(&ec->lock);
	if (ec->profile_suspended)
		return -EBUSY;
	if (ec->profile_desired == profile &&
	    ec->profile_last_requested == profile && !ec->profile_last_error)
		return count;
	ret = asus_ec_profile_apply_locked(ec, profile);
	if (ret)
		return ret;
	ec->profile_desired = profile;
	return count;
}
static DEVICE_ATTR_RW(fan_profile);

static struct attribute *asus_ec_profile_attrs[] = {
	&dev_attr_fan_profile.attr,
	NULL,
};
static const struct attribute_group asus_ec_profile_group = {
	.attrs = asus_ec_profile_attrs,
};

static void asus_ec_profile_cleanup(void *data)
{
	struct asus_ec *ec = data;
	int ret;

	guard(mutex)(&ec->lock);
	ec->profile_suspended = true;
	if (!ec->profile_managed || ec->profile_last_requested < 0)
		return;
	ret = asus_ec_profile_write_locked(ec, 0);
	if (ret)
		dev_err(&ec->client->dev, "Failed to restore normal fan profile: %d\n", ret);
}

static int asus_glymur_ec_probe(struct i2c_client *client)
{
	struct asus_ec *ec;
	int ret;

	ret = asus_glymur_ec_probe_base(client);
	if (ret)
		return ret;
	ec = i2c_get_clientdata(client);
	ec->profile_desired = -1;
	ec->profile_last_requested = -1;
	/* The command has only been tested on the A14 UX3407NA. */
	ec->profile_managed = of_device_is_compatible(client->dev.of_node,
						     "asus,zenbook-a14-ux3407na-ec");
	if (!ec->profile_managed)
		return 0;
	ret = devm_add_action_or_reset(&client->dev, asus_ec_profile_cleanup, ec);
	if (ret)
		return ret;
	return devm_device_add_group(&client->dev, &asus_ec_profile_group);
}

static int asus_glymur_ec_suspend(struct device *dev)
{
	struct asus_ec *ec = dev_get_drvdata(dev);
	int ret = 0;

	if (!ec->profile_managed)
		return asus_glymur_ec_suspend_base(dev);
	scoped_guard(mutex, &ec->lock) {
		ec->profile_suspended = true;
		if (ec->profile_desired >= 0)
			ret = asus_ec_profile_write_locked(ec, 0);
	}
	if (!ret)
		ret = asus_glymur_ec_suspend_base(dev);
	if (ret) {
		guard(mutex)(&ec->lock);
		ec->profile_suspended = false;
		if (ec->profile_desired >= 0)
			asus_ec_profile_apply_locked(ec, ec->profile_desired);
	}
	return ret;
}

static int asus_glymur_ec_resume(struct device *dev)
{
	struct asus_ec *ec = dev_get_drvdata(dev);
	int ret;

	ret = asus_glymur_ec_resume_base(dev);
	if (ret || !ec->profile_managed)
		return ret;
	guard(mutex)(&ec->lock);
	ec->profile_suspended = false;
	if (ec->profile_desired >= 0) {
		ret = asus_ec_profile_apply_locked(ec, ec->profile_desired);
		if (ret)
			dev_err(dev, "Failed to reapply fan profile after resume: %d\n", ret);
	}
	return ret;
}

static void asus_glymur_ec_shutdown(struct i2c_client *client)
{
	asus_ec_profile_cleanup(i2c_get_clientdata(client));
}
